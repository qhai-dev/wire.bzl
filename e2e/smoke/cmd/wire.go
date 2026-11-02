//go:build wireinject
// +build wireinject

package main

import (
	"github.com/google/wire"
	"github.com/qhai-dev/wire.bzl/e2e/smoke/internal/infra"
	"github.com/qhai-dev/wire.bzl/e2e/smoke/pkg/framework"
)

func InitializeApp() (*framework.App, error) {
	panic(wire.Build(
		infra.ProviderSet,
		framework.New,
	))
}
