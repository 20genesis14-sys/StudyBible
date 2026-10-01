//! Адаптер порта «Речь» на крейт `tts` (системный синтезатор ОС; ADR 0010).

use studybible_core::speech::{Error, Speech};

pub struct TtsSpeech(tts::Tts);

impl TtsSpeech {
    pub fn new() -> Result<Self, Error> {
        tts::Tts::default()
            .map(Self)
            .map_err(|e| Error(format!("синтезатор недоступен: {e}")))
    }
}

impl Speech for TtsSpeech {
    fn say(&mut self, text: &str, interrupt: bool) -> Result<(), Error> {
        self.0
            .speak(text, interrupt)
            .map(|_| ())
            .map_err(|e| Error(e.to_string()))
    }

    fn speaking(&self) -> bool {
        self.0.is_speaking().unwrap_or(false)
    }

    fn stop(&mut self) -> Result<(), Error> {
        self.0.stop().map(|_| ()).map_err(|e| Error(e.to_string()))
    }
}
