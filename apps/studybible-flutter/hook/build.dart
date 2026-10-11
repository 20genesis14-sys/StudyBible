import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Reproducible builds (F-Droid): panic-локации в .so не должны
    // содержать пути машины сборки — реестр crates и корень репо
    // режем до стабильных якорей /cargo и /src.
    final env = Platform.environment;
    final cargoHome = env['CARGO_HOME'] ??
        (Platform.isWindows
            ? '${env['USERPROFILE']}\\.cargo'
            : '${env['HOME']}/.cargo');
    // input.packageRoot — apps/studybible-flutter; корень репо — на два
    // уровня выше (там же workspace Cargo.toml).
    final pkgDir = Directory.fromUri(input.packageRoot).absolute.path;
    final repoRoot = Directory(pkgDir).parent.parent.path;
    final remaps = [
      '$cargoHome${Platform.pathSeparator}registry${Platform.pathSeparator}src=/cargo/registry/src',
      '$cargoHome${Platform.pathSeparator}git=/cargo/git',
      '$repoRoot=/src',
    ];
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: {
        'CARGO_ENCODED_RUSTFLAGS':
            remaps.map((r) => '--remap-path-prefix=$r').join('\x1f'),
      },
    ).run(input: input, output: output);
  });
}
