
.PHONY: build
build:
	sudo nixos-rebuild build --flake .#nixserv

.PHONY: test
test:
	sudo nixos-rebuild test --flake .#nixserv

.PHONY: switch
switch:
	sudo nixos-rebuild switch --flake .#nixserv
