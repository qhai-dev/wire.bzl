package infra

import "github.com/google/wire"

func NewMessage() string {
	return "Hello, Wire!"
}

var ProviderSet = wire.NewSet(NewMessage)
