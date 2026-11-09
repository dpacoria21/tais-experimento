/*
Copyright 2024 Blnk Finance Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package database

import (
	"errors"
	"strings"

	"github.com/blnkfinance/blnk/internal/apierror"
	"github.com/blnkfinance/blnk/model"
)

// optimisticLockFailurePrefix es el inicio del mensaje que devuelve updateBalance
// cuando el UPDATE ... WHERE version = v no afecta filas.
const optimisticLockFailurePrefix = "Optimistic locking failure"

// IsOptimisticLockError indica si err es el conflicto de versión de un saldo
// (control optimista). Se distingue de otros ErrConflict, como un saldo
// duplicado, por el mensaje.
func IsOptimisticLockError(err error) bool {
	if err == nil {
		return false
	}
	var apiErr apierror.APIError
	if errors.As(err, &apiErr) {
		return apiErr.Code == apierror.ErrConflict && strings.HasPrefix(apiErr.Message, optimisticLockFailurePrefix)
	}
	var apiErrPtr *apierror.APIError
	if errors.As(err, &apiErrPtr) && apiErrPtr != nil {
		return apiErrPtr.Code == apierror.ErrConflict && strings.HasPrefix(apiErrPtr.Message, optimisticLockFailurePrefix)
	}
	return false
}

// balancesInIDOrder devuelve los dos saldos ordenados por balance_id.
//
// Las filas se actualizan siempre en este orden dentro de la transacción de
// PostgreSQL. Con candados de aplicación no cambia nada (solo una transferencia
// toca cada saldo a la vez), pero sin ellos (estrategia cas) evita que A->B y
// B->A tomen los candados de fila en orden inverso y PostgreSQL aborte una de
// ellas por interbloqueo (SQLSTATE 40P01).
func balancesInIDOrder(source, destination *model.Balance) (*model.Balance, *model.Balance) {
	if destination != nil && source != nil && destination.BalanceID < source.BalanceID {
		return destination, source
	}
	return source, destination
}
