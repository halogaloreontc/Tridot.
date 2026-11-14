# Конвертер (ADR-026): JNI_OnLoad библиотеки libtridot_mp3 регистрирует
# методы класса по имени (packages/tridot_lame/src/tridot_lame_jni.c).
-keep class com.example.local_assistant.media.Mp3Native {
    native <methods>;
}
