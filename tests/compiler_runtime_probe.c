/* A CRT-free link probe: the linker must not inject these builtins for us. */
extern double __floattidf(__int128 value);
extern __int128 __divti3(__int128 numerator, __int128 denominator);
int _fltused = 0;

int runtime_probe(void) {
    volatile __int128 numerator = ((__int128)1 << 70);
    volatile __int128 denominator = 3;
    return __floattidf(__divti3(numerator, denominator)) > 0 ? 0 : 1;
}
