package lib

import "github.com/google/wire"

type Thing struct{}

func NewThing() *Thing { return &Thing{} }

var ProviderSet = wire.NewSet(NewThing)
