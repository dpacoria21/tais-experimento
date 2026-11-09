package concurrency

import "context"

// 1. Bloqueo global
//
// Un único sync.Mutex para todas las transferencias. Solo una transferencia
// retiene cuentas a la vez: elimina la retención y espera.

func (m *Manager) runGlobal(ctx context.Context, fn func(context.Context) error) error {
	m.global.Lock()
	defer m.global.Unlock()
	return fn(ctx)
}
