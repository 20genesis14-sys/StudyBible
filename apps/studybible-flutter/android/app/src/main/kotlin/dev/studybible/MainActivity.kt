package dev.studybible

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service требует Activity, отдающую кэшированный
// FlutterEngine медиа-сервису — иначе уведомление/кнопки не работают.
class MainActivity : AudioServiceActivity()
