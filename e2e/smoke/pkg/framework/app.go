package framework

import "fmt"

type App struct {
	Message string
}

func New(message string) (*App, error) {
	return &App{Message: message}, nil
}

func (a *App) Run() error {
	fmt.Println(a.Message)
	return nil
}
