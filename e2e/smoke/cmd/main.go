package main

import "log"

func main() {
	app, err := InitializeApp()
	if err != nil {
		log.Fatalf("initialize app failed: %v", err)
	}

	if err := app.Run(); err != nil {
		log.Fatalf("run app failed: %v", err)
	}
}
