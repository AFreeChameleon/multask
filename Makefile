main:
	cargo build
spawn:
	cd mult_spawn
	cargo build
	cd ..
lib:
	cd mult_lib
	cargo build
	cd ..
all:
	cargo build --workspace
