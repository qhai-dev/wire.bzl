package adapter

import (
	"github.com/google/wire"
	"github.com/qhai-dev/wire.bzl/e2e/smoke/internal/application"
)

type Controller struct {
	Service *application.Service
}

func NewController(svc *application.Service) *Controller {
	return &Controller{Service: svc}
}

var ProviderSet = wire.NewSet(NewController)
