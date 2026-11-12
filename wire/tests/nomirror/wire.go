//go:build wireinject
// +build wireinject

package nomirror

import (
	"example.com/unrelated/lib"
	"github.com/google/wire"
)

func InitializeThing() *lib.Thing {
	panic(wire.Build(lib.ProviderSet))
}
