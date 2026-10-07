# musl-sysroot

Prebuilt musl sysroots for the [`llvm-runtime`](https://github.com/holepunchto/llvm-runtime) compiler. musl, the Linux kernel headers, and the C++ standard library are built from source for each supported target.

```
npm i musl-sysroot
```

The compiler runtime libraries ship with `llvm-runtime` itself. Link with `--rtlib=compiler-rt`, `--unwindlib=libunwind`, and `-stdlib=libc++`.

## Usage

```js
const sysroot = require('musl-sysroot')

sysroot('aarch64-linux-musl')
// /path/to/node_modules/musl-sysroot-aarch64-linux-musl
```

## License

Apache-2.0
