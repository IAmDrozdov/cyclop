#!/bin/bash
# Собирает liblocalvqe.dylib (эхоподавитель) для Apple Silicon из закреплённой
# ревизии и скачивает его модель. Результат — .build/localvqe/; повторный запуск
# при готовом результате ничего не делает.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/localvqe"
SOURCE="$OUT/source"
SOURCE_REV="f53063c9eb2a85f96479867d1dd911dc3bf6319b"
MODEL_NAME="localvqe-v1.4-aec-200K-f32.gguf"
MODEL_REV="29ca38495cba9d6393a92a4dd890f28dd81f758d"
MODEL_URL="https://huggingface.co/LocalAI-io/LocalVQE/resolve/$MODEL_REV/$MODEL_NAME"
MODEL_SHA="b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"
LIB="$OUT/lib/liblocalvqe.dylib"
MODEL="$OUT/model/$MODEL_NAME"

if [ -f "$LIB" ] && [ -f "$MODEL" ] && [ -d "$OUT/licenses" ]; then
    echo "LocalVQE уже собран: $OUT"
    exit 0
fi

command -v cmake >/dev/null || {
    echo "!!! для эхоподавителя нужен cmake: brew install cmake" >&2
    echo "    (или CYCLOP_SKIP_LOCALVQE=1, чтобы собрать без него)" >&2
    exit 1
}

mkdir -p "$OUT/model" "$OUT/lib" "$OUT/licenses"

if [ ! -d "$SOURCE/.git" ]; then
    git clone --no-checkout https://github.com/localai-org/LocalVQE.git "$SOURCE"
    git -C "$SOURCE" checkout --detach "$SOURCE_REV"
    git -C "$SOURCE" submodule update --init --recursive
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_REV" \
    || { echo "!!! исходники LocalVQE не на закреплённой ревизии $SOURCE_REV" >&2; exit 1; }

if [ ! -f "$MODEL" ]; then
    curl -fL --retry 3 --output "$MODEL.tmp" "$MODEL_URL"
    mv "$MODEL.tmp" "$MODEL"
fi
printf '%s  %s\n' "$MODEL_SHA" "$MODEL" | shasum -a 256 -c - >/dev/null \
    || { rm -f "$MODEL"; echo "!!! контрольная сумма модели не сошлась" >&2; exit 1; }

# CMake 4 отвергает проекты, объявляющие совместимость ниже 3.5, — их тут несколько.
BUILD="$OUT/build-arm64"
cmake -S "$SOURCE/ggml" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLOCALVQE_BUILD_SHARED=ON \
    -DGGML_METAL=OFF \
    -DGGML_BLAS=OFF
cmake --build "$BUILD" --target localvqe_shared -j 4

BUILT="$(/usr/bin/find "$BUILD" -maxdepth 1 -name 'liblocalvqe*.dylib' -type f | head -1)"
test -n "$BUILT" || { echo "!!! liblocalvqe.dylib не собралась" >&2; exit 1; }
# Ничего, кроме системных библиотек, в зависимостях быть не должно; проверка идёт
# до копирования, чтобы отвергнутая библиотека не попала в кэш и в бандл.
install_name_tool -id @rpath/liblocalvqe.dylib "$BUILT"
if otool -L "$BUILT" | awk '/^\t/{print $1}' \
    | grep -Ev '^(@rpath/liblocalvqe\.dylib|/usr/lib/|/System/Library/)' >/dev/null; then
    echo "!!! у LocalVQE есть несистемная зависимость:" >&2
    otool -L "$BUILT" >&2
    exit 1
fi
cp "$BUILT" "$LIB"

cp "$SOURCE/LICENSE" "$OUT/licenses/LocalVQE-LICENSE"
cp "$SOURCE/ggml/vendor/ggml/LICENSE" "$OUT/licenses/ggml-LICENSE"
echo "LocalVQE готов: $OUT"
