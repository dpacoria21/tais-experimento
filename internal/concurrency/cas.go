package concurrency

import "context"

// 3. CAS sobre estado inmutable
//
// Sin candados en la aplicación. Cada saldo se guarda con
//
//	UPDATE blnk.balances SET ..., version = version + 1
//	WHERE balance_id = $1 AND version = $11      -- la versión que se leyó
//
// (database/balance.go, updateBalance). Si otra transferencia ganó, el UPDATE
// no afecta filas y se reintenta tras una pausa aleatoria; fn relee los saldos
// en cada intento. Elimina la exclusión mutua bloqueante.

func (m *Manager) runCAS(ctx context.Context, fn func(context.Context) error, isVersionConflict func(error) bool) error {
	return m.retry(ctx, func() (bool, error) {
		err := fn(ctx)
		return isVersionConflict(err), err
	})
}
