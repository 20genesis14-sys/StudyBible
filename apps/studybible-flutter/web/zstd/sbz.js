// Шим для веб-моста StudyBible: единый глобал
// window.sbZstdDecompress(payload) -> Promise<Uint8Array>.
// payload — чистый zstd-кадр (без заголовка SBZ1: его срезает Dart).
// Декодер — @bokuweb/zstd-wasm 0.0.27 (MIT), вендорные файлы рядом.
// Наши .sbz пишутся потоковым zstd без размера контента в заголовке,
// поэтому defaultHeapSize задаём от сжатого объёма (покрывает ×8).
import { init, decompress } from './index.web.js';

const ready = init();
window.sbZstdDecompress = (payload) =>
  ready.then(() =>
    decompress(payload, {
      defaultHeapSize: Math.max(payload.byteLength * 8, 32 * 1024 * 1024),
    }),
  );
