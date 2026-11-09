// Package concurrency implementa las estrategias de control de concurrencia
// que el experimento compara al transferir entre dos saldos. Cada estrategia
// está en su propio archivo:
//
//	global.go        1. Bloqueo global
//	ordered.go       2. Bloqueo por cuenta con orden total
//	cas.go           3. CAS sobre estado inmutable
//	waitdie.go       4. Wait-Die
//	noprevention.go  5. Control sin prevención (detector de ciclos)
//
// La estrategia "original" (candados Redis de Blnk) no pasa por este paquete.
//
// Las estrategias coordinan goroutines de un solo proceso: todas las
// transferencias deben llegar al mismo contenedor server con skip_queue=true.
package concurrency

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Strategy identifica una estrategia de control de concurrencia.
type Strategy string

const (
	StrategyOriginal     Strategy = "original"
	StrategyGlobal       Strategy = "global"
	StrategyOrdered      Strategy = "ordered"
	StrategyCAS          Strategy = "cas"
	StrategyWaitDie      Strategy = "wait_die"
	StrategyNoPrevention Strategy = "no_prevention"
)

var strategies = []Strategy{StrategyOriginal, StrategyGlobal, StrategyOrdered, StrategyCAS, StrategyWaitDie, StrategyNoPrevention}

// ParseStrategy convierte el valor de configuración en una Strategy.
// La cadena vacía equivale a original.
func ParseStrategy(value string) (Strategy, error) {
	v := Strategy(strings.ToLower(strings.TrimSpace(value)))
	if v == "" {
		return StrategyOriginal, nil
	}
	for _, s := range strategies {
		if s == v {
			return s, nil
		}
	}
	return "", fmt.Errorf("unknown concurrency strategy %q (valid: original, global, ordered, cas, wait_die, no_prevention)", value)
}

// ErrRetriesExhausted indica que una transferencia abortada (conflicto CAS,
// muerte en Wait-Die o víctima de interbloqueo) no logró completarse dentro
// del tiempo de reintentos.
var ErrRetriesExhausted = errors.New("concurrency retries exhausted")

// Manager aplica la estrategia configurada. Hay uno por proceso.
type Manager struct {
	strategy     Strategy
	retryTimeout time.Duration

	global   sync.Mutex       // 1. bloqueo global
	ordered  mutexPerAccount  // 2. un sync.Mutex por cuenta
	waitDie  lockTable        // 4. candados con la marca de tiempo del dueño
	detector deadlockDetector // 5. candados con grafo de espera

	clock atomic.Int64 // marcas de tiempo lógicas (4) e identificadores de transferencia (5)

	// Contadores acumulados desde el arranque (Tabla 3 del informe). El
	// experimento toma la diferencia antes y después de cada medición.
	transfers atomic.Int64 // transferencias que entraron a Execute
	retries   atomic.Int64 // intentos repetidos tras un aborto (CAS, Wait-Die, víctima)
	exhausted atomic.Int64 // transferencias que agotaron el tiempo de reintentos
}

// Counters es la lectura de los contadores del Manager.
type Counters struct {
	Strategy          Strategy `json:"strategy"`
	Transfers         int64    `json:"transfers"`
	Retries           int64    `json:"retries"`
	RetriesExhausted  int64    `json:"retries_exhausted"`
	DeadlocksDetected int64    `json:"deadlocks_detected"`
}

// Counters devuelve los contadores acumulados.
func (m *Manager) Counters() Counters {
	return Counters{
		Strategy:          m.strategy,
		Transfers:         m.transfers.Load(),
		Retries:           m.retries.Load(),
		RetriesExhausted:  m.exhausted.Load(),
		DeadlocksDetected: m.detector.deadlocks.Load(),
	}
}

// New crea un Manager. retryTimeout es el tiempo máximo que una transferencia
// abortada sigue reintentando (estrategias 3, 4 y 5).
func New(strategy Strategy, retryTimeout time.Duration) *Manager {
	return &Manager{strategy: strategy, retryTimeout: retryTimeout}
}

// Strategy devuelve la estrategia activa.
func (m *Manager) Strategy() Strategy { return m.strategy }

// Execute ejecuta fn con acceso a los saldos source y destination según la
// estrategia activa. fn lee los saldos, calcula y guarda; debe poder repetirse,
// porque las estrategias 3, 4 y 5 la reintentan. isVersionConflict reconoce el
// error del UPDATE ... WHERE version = v que no afectó filas.
func (m *Manager) Execute(ctx context.Context, source, destination string, fn func(context.Context) error, isVersionConflict func(error) bool) error {
	m.transfers.Add(1)
	switch m.strategy {
	case StrategyGlobal:
		return m.runGlobal(ctx, fn)
	case StrategyOrdered:
		return m.runOrdered(ctx, source, destination, fn)
	case StrategyCAS:
		return m.runCAS(ctx, fn, isVersionConflict)
	case StrategyWaitDie:
		return m.runWaitDie(ctx, source, destination, fn)
	case StrategyNoPrevention:
		return m.runNoPrevention(ctx, source, destination, fn)
	}
	return fmt.Errorf("strategy %q is not handled by the concurrency manager", m.strategy)
}

// requestOrder devuelve origen y luego destino; una sola vez si son la misma cuenta.
func requestOrder(source, destination string) []string {
	if source == destination {
		return []string{source}
	}
	return []string{source, destination}
}

// ascendingOrder devuelve las cuentas en orden ascendente de ID.
func ascendingOrder(source, destination string) []string {
	if destination < source {
		return requestOrder(destination, source)
	}
	return requestOrder(source, destination)
}

// acquireAll toma los candados de las cuentas en el orden dado. Si uno falla,
// suelta los que ya tenía y devuelve el error; si no, devuelve la función que
// los suelta en orden inverso.
func acquireAll(accounts []string, lock func(account string) error, unlock func(account string)) (release func(), err error) {
	held := make([]string, 0, len(accounts))
	release = func() {
		for i := len(held) - 1; i >= 0; i-- {
			unlock(held[i])
		}
	}
	for _, account := range accounts {
		if err := lock(account); err != nil {
			release()
			return nil, err
		}
		held = append(held, account)
	}
	return release, nil
}

// Política de reintentos: la misma del candado Redis original (internal/lock).
const (
	backoffBase = 5 * time.Millisecond
	backoffMax  = 100 * time.Millisecond
)

// retry ejecuta attempt mientras pida reintentar, con una pausa aleatoria entre
// intentos, hasta agotar retryTimeout.
func (m *Manager) retry(ctx context.Context, attempt func() (retry bool, err error)) error {
	deadline := time.Now().Add(m.retryTimeout)
	for n := 0; ; n++ {
		again, err := attempt()
		if !again {
			return err
		}
		if !time.Now().Before(deadline) {
			m.exhausted.Add(1)
			// La causa va como texto (%v) para que la API responda con el código
			// de aborto (GEN_CONCURRENCY_ABORTED) y no con el de la causa.
			return fmt.Errorf("%w after %d attempts (strategy %s): %v", ErrRetriesExhausted, n+1, m.strategy, err)
		}
		m.retries.Add(1)
		if err := sleep(ctx, backoff(n, deadline)); err != nil {
			return err
		}
	}
}

// backoff elige una pausa al azar por debajo de un tope que empieza en 5 ms y
// se duplica en cada intento hasta 100 ms, sin pasar del plazo.
func backoff(attempt int, deadline time.Time) time.Duration {
	ceiling := min(backoffBase<<min(attempt, 5), backoffMax)
	pause := time.Duration(rand.Int63n(int64(ceiling))) + time.Millisecond
	return min(pause, time.Until(deadline))
}

func sleep(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return nil
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// ownedLock es un candado exclusivo que recuerda a su dueño y admite una espera
// cancelable; sync.Mutex no ofrece ninguna de las dos cosas, y Wait-Die y el
// detector de interbloqueos necesitan ambas.
type ownedLock struct {
	owner    int64         // 0 = libre
	released chan struct{} // se cierra al soltarlo y despierta a quienes esperan
}

// lockTable guarda un ownedLock por cuenta.
type lockTable struct {
	mu    sync.Mutex
	locks map[string]*ownedLock
}

// entry devuelve el candado de la cuenta y lo crea si no existe. Requiere t.mu.
func (t *lockTable) entry(account string) *ownedLock {
	if t.locks == nil {
		t.locks = map[string]*ownedLock{}
	}
	l, ok := t.locks[account]
	if !ok {
		l = &ownedLock{}
		t.locks[account] = l
	}
	return l
}

// take asigna el candado libre a owner. Requiere t.mu.
func (l *ownedLock) take(owner int64) {
	l.owner = owner
	l.released = make(chan struct{})
}

// release suelta el candado de la cuenta si owner es su dueño.
func (t *lockTable) release(owner int64, account string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if l := t.locks[account]; l != nil && l.owner == owner {
		l.owner = 0
		close(l.released)
	}
}
