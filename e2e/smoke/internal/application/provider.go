package application

import (
	"github.com/google/wire"
)

type Service struct {
}

func NewService() *Service {
	return &Service{}
}

var ProviderSet = wire.NewSet(NewService)
