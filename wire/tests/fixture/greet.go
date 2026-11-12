package fixture

import "github.com/google/wire"

type Greeter struct{ Name string }

func NewGreeter() *Greeter { return &Greeter{Name: "fixture"} }

var ProviderSet = wire.NewSet(NewGreeter)
