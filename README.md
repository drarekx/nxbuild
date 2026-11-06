# NX Build

App de macOS (SwiftUI) para construir juegos de Switch como app de Mac o IPA de iPhone con [nxnative](https://github.com/seedds/nxnative), y jugarlos desde una biblioteca.

Es la interfaz de `scripts/build_ipa_from_nsp.py` de nxnative: lee su progreso (`--progress json`), explica los errores conocidos y propone el siguiente paso. NX Build no incluye nxnative ni ningún juego, clave o firmware: necesitas tus propios volcados y tu `prod.keys`.

## Qué necesita cada cosa

| Para… | Hace falta |
|---|---|
| **Construir** un juego | Un clon de [nxnative](https://github.com/seedds/nxnative) (Ajustes › Repositorio nxnative), Xcode con su compilador Metal, Python 3.12+ con sus módulos y Homebrew. Dependencias (⇧⌘D) lo comprueba e instala, salvo el clon de nxnative. |
| **Jugar** y cargar partidas | Nada más: cada app de juego construida lleva dentro todo lo que necesita. Funciona sin nxnative, sin Python y sin Xcode, también en otro Mac con Apple Silicon y la versión de macOS que pida el juego. Copiada a otro Mac, quita la cuarentena: **Permitir abrir** en NX Build o `xattr -dr com.apple.quarantine "Juego.app"`. |
| **Partidas en la nube** | La misma carpeta de iCloud Drive elegida en cada Mac (o en el iPhone). |

## Instalar

```sh
curl -fsSL https://raw.githubusercontent.com/drarekx/nxbuild/main/install.sh | bash
```

El instalador descarga la última versión, comprueba su SHA-256, la deja en `/Applications` (o `~/Applications`) y la abre. Una versión concreta: `… | bash -s -- --version 1.2.0`.

Requisitos: Mac con Apple Silicon y macOS 15 o posterior. Para construir, clona nxnative (`git clone https://github.com/seedds/nxnative.git`) e indica su carpeta en Ajustes; el resto se instala desde **Dependencias** (⇧⌘D).

## Actualizar

La app busca versiones nuevas al abrirse y una vez al día; también en **NX Build › Buscar actualizaciones…**. Descarga la versión, comprueba su huella, sustituye la app y la vuelve a abrir.
## Qué hace

- **Biblioteca**: las apps de juego construidas, con su estado de partidas en la nube, opciones de lanzamiento, DLC dentro de la app, log y copias de seguridad. Doble clic para jugar.
- **Nueva build**: arrastra NSP, NSZ, DLC o la carpeta del juego, o un juego de Switch 2 como `.nup` o carpeta de dump (sin `prod.keys`); comprueba las claves (`prod.keys`) descifrando las cabeceras NCA, avisa de carpetas en la nube y del compilador Metal, y construye.
- **Build en curso**: etapas, progreso, tiempo restante y log; aviso en el Dock y notificación al terminar. Cancelar para todo el grupo de procesos.
- **Errores**: clasifica los mensajes del script y ofrece el arreglo (abrir Dependencias, reintentar con el permiso adecuado, copiar un diagnóstico sin claves ni rutas personales).
- **Partidas en la nube**: elige la carpeta (iCloud Drive) por la que cada juego sincroniza su partida con otro Mac o el iPhone.
- **Filebox en el inicio**: el carrusel muestra también los juegos de Filebox que no tienes (se descargan e instalan con A) y deja borrar los instalados (a la Papelera). Los juegos se emparejan por title ID; la Colección no deja descargar lo que ya está en la biblioteca.
- **Subir a Filebox**: desde la biblioteca, comprime la app construida, la copia por SMB a la carpeta de entrada de Filebox (configurable en Ajustes; monta el recurso si hace falta) y pide la importación, con el progreso de cada paso. En otro Mac, la Colección la instala directamente en la biblioteca.
- **Inicio tipo consola**: carrusel de juegos con portada (icono del NSP o portada de Filebox, a elegir por juego), menú de botones redondos y barra de atajos; se maneja con teclado (← → ↩ X Y + Esc) o con un mando (cruceta, A jugar, B volver, X opciones, Y log, + nueva build).
- **Colección (Filebox)**: conecta con la API de Filebox (dirección + token de API, guardado en un archivo 0600), muestra la colección con portadas, busca y filtra, descarga los .zip con reanudación (Range), comprueba el SHA-256, los descomprime y abre la build con los NSP/XCI de dentro.
- **Juegos copiados de otro Mac**: detecta la marca de cuarentena que pone macOS (AirDrop, descargas) y la quita con **Permitir abrir** (pide la contraseña de administrador si los archivos son de solo lectura o de otro usuario). Si macOS lo impide por la protección **Gestión de apps**, ofrece una copia limpia en `~/Applications` (rsync, nace sin la marca) o dar ese permiso a NX Build en Ajustes, sin tocar la firma; avisa si el juego pide una versión de macOS más nueva que la del Mac.
- **Liberar espacio**: borra lo que la siguiente build vuelve a generar.
- **Mover a otro disco**: desde la biblioteca, mueve el juego entero (la app, su carpeta de build con la caché de shaders y los NSP / NUP / dump de los que salió, aunque estuvieran enlazados) a otro disco; copia con ditto, comprueba los bytes y solo entonces borra el original. Avisa si el destino no cabe o es exFAT.

## Desarrollo

```sh
swift build                 # comprobación rápida
swift test                  # tests (algunos usan juegos y claves locales y se saltan si no están)
./make_app.sh               # ../NX Build.app, versión = última etiqueta v*
OUT=build ZIP=1 VERSION=1.2.0 ./make_app.sh   # build/NX Build.app + build/NXBuild.zip + .sha256
```

## Publicar una versión

```sh
git tag v1.2.0 && git push origin v1.2.0
```

`.github/workflows/release.yml` compila con esa versión y publica `NXBuild.zip` y `NXBuild.zip.sha256`. La app no está notarizada (firma ad hoc); el instalador y el actualizador quitan la cuarentena.

Mejoras pendientes: [MEJORAS.md](MEJORAS.md).
