#ifndef MEDIA_REMOTE_BRIDGE_H
#define MEDIA_REMOTE_BRIDGE_H

// Точки входа вызываются системным /usr/bin/perl через DynaLoader::dl_install_xsub
// (см. Resources/mediaremote.pl). Сигнатура совместима с XSUB: (pTHX_ CV *cv).

/// Бесконечно печатает в stdout по строке JSON на каждое изменение «Сейчас играет».
__attribute__((visibility("default"))) void mh_stream(void *a, void *b);

/// Выполняет одну команду из окружения (MH_COMMAND или MH_SEEK) и завершает процесс.
__attribute__((visibility("default"))) void mh_send(void *a, void *b);

#endif
