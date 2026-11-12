//go:build wireinject
// +build wireinject

package fixture

import "github.com/google/wire"

func InitializeGreeter() *Greeter {
	panic(wire.Build(ProviderSet))
}
