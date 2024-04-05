mix compile
tar -czf release/ex_webp-v0.1.3-nif-2.15-x86_64-pc-windows-msvc.dll.tar.gz _build/dev/lib/ex_webp/libex_webp.dll
cp priv/native/libex_webp.dll priv/native/webp-v0.1.3-nif-2.15-x86_64-pc-windows-msvc.dll
mix rustler_precompiled.download ExWebp --all --print