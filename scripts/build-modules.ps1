# Сборка модулей *.sb из распакованных источников (scripts/fetch-data.ps1).
# Результат — <корень данных>\modules\<id>.sb.
cargo run -q -p studybible-cli -- module build --defs data\modules.json
exit $LASTEXITCODE
