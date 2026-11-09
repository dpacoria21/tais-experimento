package concurrency

import (
	"context"
	"errors"
)

// 4. Wait-Die
//
// Un candado por cuenta que guarda la marca de tiempo de su dueño. Si quien
// pide es más antigua que el dueño, espera; si es más joven, muere: suelta lo
// que tenía y reintenta con su misma marca. Solo las transferencias más
// antiguas esperan a las más jóvenes: elimina la espera circular.
//
// Los candados se toman en el orden de la petición, sin ordenar: la prevención
// viene de la regla de Wait-Die, no de un orden.

var errWaitDieAbort = errors.New("wait-die: younger transfer aborted")

// lockWaitDie toma la cuenta para la transferencia con marca ts.
func (t *lockTable) lockWaitDie(ctx context.Context, ts int64, account string) error {
	for {
		t.mu.Lock()
		l := t.entry(account)
		if l.owner == 0 { // libre: la toma
			l.take(ts)
			t.mu.Unlock()
			return nil
		}
		if ts > l.owner { // más joven que el dueño: muere
			t.mu.Unlock()
			return errWaitDieAbort
		}
		released := l.released // más antigua: espera a que la suelten
		t.mu.Unlock()
		select {
		case <-released:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (m *Manager) runWaitDie(ctx context.Context, source, destination string, fn func(context.Context) error) error {
	ts := m.clock.Add(1) // menor = más antigua; se conserva en cada reintento
	accounts := requestOrder(source, destination)

	return m.retry(ctx, func() (bool, error) {
		release, err := acquireAll(accounts,
			func(account string) error { return m.waitDie.lockWaitDie(ctx, ts, account) },
			func(account string) { m.waitDie.release(ts, account) },
		)
		if errors.Is(err, errWaitDieAbort) {
			return true, err // ya soltó lo que tenía: reintentar
		}
		if err != nil {
			return false, err
		}
		defer release()
		return false, fn(ctx)
	})
}
