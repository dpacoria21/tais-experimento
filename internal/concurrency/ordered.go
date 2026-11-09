package concurrency

import (
	"context"
	"sync"
)

// 2. Bloqueo por cuenta con orden total
//
// Un sync.Mutex por cuenta; se toman en orden ascendente de ID. Todas las
// transferencias bloquean en el mismo orden (A->B y B->A toman primero A):
// elimina la espera circular.

// mutexPerAccount guarda un sync.Mutex por cuenta. Su mu protege solo el mapa.
type mutexPerAccount struct {
	mu    sync.Mutex
	locks map[string]*sync.Mutex
}

func (t *mutexPerAccount) get(account string) *sync.Mutex {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.locks == nil {
		t.locks = map[string]*sync.Mutex{}
	}
	l, ok := t.locks[account]
	if !ok {
		l = &sync.Mutex{}
		t.locks[account] = l
	}
	return l
}

func (m *Manager) runOrdered(ctx context.Context, source, destination string, fn func(context.Context) error) error {
	// sync.Mutex.Lock no falla, así que acquireAll no puede devolver error.
	release, _ := acquireAll(ascendingOrder(source, destination),
		func(account string) error { m.ordered.get(account).Lock(); return nil },
		func(account string) { m.ordered.get(account).Unlock() },
	)
	defer release()
	return fn(ctx)
}
