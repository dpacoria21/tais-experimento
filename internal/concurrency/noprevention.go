package concurrency

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"github.com/sirupsen/logrus"
)

// 5. Control sin prevención
//
// Un candado por cuenta, primero origen y luego destino: A->B y B->A pueden
// quedarse cada una con una cuenta esperando la otra. No se evita el
// interbloqueo: un detector de ciclos lo cuenta y aborta a una víctima, que
// suelta sus candados y reintenta. Sirve para demostrar que el interbloqueo
// ocurre.

// detectInterval es cuánto espera un candado antes de buscar un ciclo
// (como deadlock_timeout en PostgreSQL).
const detectInterval = 100 * time.Millisecond

var errDeadlockVictim = errors.New("deadlock victim")

// deadlockDetector son los candados por cuenta más el grafo de espera.
type deadlockDetector struct {
	lockTable
	waitsFor  map[int64]string // transferencia -> cuenta que espera
	deadlocks atomic.Int64     // interbloqueos detectados desde el arranque
}

// lock toma la cuenta para txn. Si tras detectInterval sigue esperando y está
// en un ciclo, txn es la víctima y devuelve errDeadlockVictim.
func (d *deadlockDetector) lock(ctx context.Context, txn int64, account string) error {
	for {
		d.mu.Lock()
		l := d.entry(account)
		if l.owner == 0 { // libre: la toma
			l.take(txn)
			delete(d.waitsFor, txn)
			d.mu.Unlock()
			return nil
		}
		if d.waitsFor == nil {
			d.waitsFor = map[int64]string{}
		}
		d.waitsFor[txn] = account // arista del grafo: txn espera esta cuenta
		released := l.released
		d.mu.Unlock()

		timer := time.NewTimer(detectInterval)
		select {
		case <-released: // la soltaron: volver a intentar
			timer.Stop()
		case <-ctx.Done():
			timer.Stop()
			d.mu.Lock()
			delete(d.waitsFor, txn)
			d.mu.Unlock()
			return ctx.Err()
		case <-timer.C: // sigue esperando: ¿hay ciclo?
			if d.abortIfDeadlocked(txn) {
				return errDeadlockVictim
			}
		}
	}
}

// abortIfDeadlocked: si txn está en un ciclo, deja de esperar y es la víctima.
// Se decide con d.mu tomado, así que cada ciclo tiene una sola víctima: las
// demás transferencias del ciclo ya no la ven esperando.
func (d *deadlockDetector) abortIfDeadlocked(txn int64) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.inCycle(txn) {
		return false
	}
	delete(d.waitsFor, txn)
	total := d.deadlocks.Add(1)
	logrus.WithFields(logrus.Fields{"victim": txn, "deadlocks_detected": total}).Warn("deadlock detected, victim aborted")
	return true
}

// inCycle sigue la cadena txn -> cuenta que espera -> dueño -> cuenta que
// espera -> ... y devuelve true si vuelve a txn. Requiere d.mu.
func (d *deadlockDetector) inCycle(txn int64) bool {
	visited := map[int64]bool{}
	for current := txn; !visited[current]; {
		visited[current] = true
		account, waiting := d.waitsFor[current]
		if !waiting {
			return false
		}
		owner := d.entry(account).owner
		if owner == txn {
			return true
		}
		if owner == 0 {
			return false
		}
		current = owner
	}
	return false // ciclo que no incluye a txn: lo resolverá uno de sus miembros
}

func (m *Manager) runNoPrevention(ctx context.Context, source, destination string, fn func(context.Context) error) error {
	txn := m.clock.Add(1)
	accounts := requestOrder(source, destination)

	return m.retry(ctx, func() (bool, error) {
		release, err := acquireAll(accounts,
			func(account string) error { return m.detector.lock(ctx, txn, account) },
			func(account string) { m.detector.release(txn, account) },
		)
		if errors.Is(err, errDeadlockVictim) {
			return true, err // la víctima ya soltó lo que tenía: reintentar
		}
		if err != nil {
			return false, err
		}
		defer release()
		return false, fn(ctx)
	})
}
