main:
	cargo build
spawn:
	cd mult_spawn; cargo build; cd ..
lib:
	cc -c mult_lib/src/c/mult.c -o mult_lib/mult.o
	cc -shared mult_lib/mult.o -o mult_lib/libmult.so
	ar rcs mult_lib/libmult.a mult_lib/mult.o
	cd mult_lib; cargo build; cd ..
all:
	make lib
	make spawn
	make main
