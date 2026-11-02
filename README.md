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
- **Nueva build**: arrastra NSP, NSZ, DLC o la carpeta del juego; comprueba las claves (`prod.keys`) descifrando las cabeceras NCA, avisa de carpetas en la nube y del compilador Metal, y construye.
- **Build en curso**: etapas, progreso, tiempo restante y log; aviso en el Dock y notificación al terminar. Cancelar para todo el grupo de procesos.
- **Errores**: clasifica los mensajes del script y ofrece el arreglo (abrir Dependencias, reintentar con el permiso adecuado, copiar un diagnóstico sin claves ni rutas personales).
- **Partidas en la nube**: elige la carpeta (iCloud Drive) por la que cada juego sincroniza su partida con otro Mac o el iPhone.
- **Juegos copiados de otro Mac**: detecta la marca de cuarentena que pone macOS (AirDrop, descargas) y la quita con **Permitir abrir** (pide la contraseña de administrador si los archivos son de solo lectura o de otro usuario), sin tocar la firma; avisa si el juego pide una versión de macOS más nueva que la del Mac.
- **Liberar espacio**: borra lo que la siguiente build vuelve a generar.

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
