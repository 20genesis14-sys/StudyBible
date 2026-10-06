//! Тонкий API ядра StudyBible для Flutter через flutter_rust_bridge.
//!
//! `module` — чтение модулей .sb (каталог, книги, главы);
//! `userdata` — прогресс чтения и последняя позиция через store::UserData.

pub mod module;
pub mod userdata;
pub mod voice;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Стандартные утилиты frb (обработка паник, лог).
    flutter_rust_bridge::setup_default_user_utils();
}
