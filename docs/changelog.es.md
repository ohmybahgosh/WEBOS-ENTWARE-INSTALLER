# Registro de cambios

Los cambios de WebOS Entware en español, para la pantalla Novedades de la aplicación.  Los títulos de sección (`### Added`, `### Changed`, `### Fixed`) quedan en inglés para que coincidan con el [CHANGELOG.md](../CHANGELOG.md) original, que tiene todas las versiones: la aplicación los traduce sola.

## [2.16.1] - 2026-11-21

### Added

- **Novedades en tu idioma.**  Después de que la aplicación se actualice, sus cambios se muestran en español o ruso si la aplicación está en uno de ellos, con los títulos Añadido, Cambiado y Corregido, igual que LG-USB-2-ETH0 y FW Block.  Los registros de cambios traducidos están en [`docs/changelog.es.md`](changelog.es.md) y [`docs/changelog.ru.md`](changelog.ru.md).
- **Ayuda, Novedades** muestra los cambios de esta versión en cualquier momento, no solo una vez después de actualizar.
- **La aplicación muestra qué trae una actualización antes de instalarla,** en su idioma cuando la versión tiene esa traducción.  Cada versión lleva ahora sus registros de cambios, comprobados con su SHA256SUMS igual que la propia aplicación.

### Security

- **Las versiones van firmadas, y la aplicación solo se actualiza a una firmada.**  El `SHA256SUMS` de cada versión se firma con la clave del proyecto en el ordenador del autor, nunca en GitHub, y el instalador comprueba la firma con `openssl` contra la clave que lleva dentro (o su copia de respaldo sin conexión) antes de ofrecer, mostrar o instalar una actualización.  Cada archivo que la aplicación toma de una versión se comprueba con esas sumas firmadas, así que una versión subida por otra persona no se instala.  Las claves están en [`release-signing-key.pub`](../release-signing-key.pub) y [`SECURITY.md`](../SECURITY.md#release-signing), igual que en LG-USB-2-ETH0.

## [2.16.0] - 2026-11-20

### Added

- **La aplicación del televisor y el panel del móvil en español y ruso,** además de inglés.  La aplicación sigue el idioma del televisor, o elige uno en **Ayuda**, **Idioma**; el panel del móvil sigue el del móvil.  Están traducidos los complementos, las categorías y los consejos de Paquetes, la referencia de comandos SSH, y los problemas y notas que la comprobación completa encuentra en la pantalla principal.  Los registros de tareas, la propia comprobación completa y los informes para GitHub quedan en inglés, igual que por SSH.  Una prueba nueva, `tests/check-i18n.js`, hace fallar el CI si algún texto de la aplicación o del panel no tiene traducción.

### Changed

- **El menú de la aplicación tiene pestañas y letra más grande,** como LG-USB-2-ETH0, SSH Doctor y FW Block, para que se lea bien en un televisor pequeño: **Paquetes** (actualizaciones de paquetes, paquetes, complementos), **Entware** (una actualización de la aplicación, comprobar y reparar, mover, desinstalar) y **Ayuda** (comandos SSH, la comprobación completa y los registros, informes para GitHub, idioma).  Los botones miden 40px en vez de 27px, y la tarjeta de estado, las ventanas emergentes y la pantalla Paquetes también son más grandes.  La tarjeta de estado muestra lo que importa, y deja nano, los certificados y locate para cuando alguno necesita atención.  La aplicación se abre en Paquetes, o en Entware cuando hace falta instalar, reparar o actualizar la aplicación.
- **Una lista en una ventana emergente nunca muestra una fila cortada por la mitad:** empieza en el borde superior de una fila, y la fila que no cabe queda para el siguiente desplazamiento.

### Fixed

- **Desinstalar limpia todo lo suyo:** detiene el panel del móvil y cualquier programa que siga ejecutándose desde Entware (como `tv serve` o tmux) antes de quitarlo, para que nada siga funcionando desde archivos borrados.  Los scripts de inicio creados con `tv autostart` se desactivan (usan `tv`, que se va con Entware) pero se conservan, y sus archivos temporales en `/tmp` se borran.  La sesión SSH de otra persona no se toca.
- **Dos tareas iniciadas en el mismo momento ya no pueden ejecutarse las dos donde `mkdir` informa de éxito al perder una carrera,** como hace uutils coreutils de la 0.8 a la 0.10 (Ubuntu 26.04).  El bloqueo de tareas y el de inicio se toman ahora con un archivo que solo un proceso puede crear, no solo con `mkdir`.
