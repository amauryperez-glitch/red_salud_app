# Red de Salud · Flask + PostgreSQL

Aplicación web para la red regional de bancos de sangre y donación de órganos.

## 1. Estructura

```
app.py                                   rutas de Flask (solo CALL a procedimientos + FETCH de sus cursores)
requirements.txt                         Flask, psycopg 3
db/01_schema_banco_sangre_organos.sql    CREATE ROLE + CREATE DATABASE + tablas + índices
db/02_inserts_banco_sangre_organos.sql   datos de prueba (contraseñas con hash bcrypt)
db/03_funciones.sql                      9 funciones de apoyo (no cuentan como procedimientos)
db/04_procedimientos.sql                 41 procedimientos almacenados (16 de reglas de negocio + 25 de consulta y CRUD)
db/05_vistas.sql                         5 vistas
db/06_consultas.sql                      consultas con JOIN y complementarias (solo lectura)
db/07_pruebas_procedimientos.sql         pruebas de los procedimientos (opcional, agrega datos)
db/07_resultado_pruebas.txt              resultado obtenido de esas pruebas
templates/                               pantallas (Jinja2; encabezado.html y pie.html se incluyen en cada una)
static/css/estilos.css  static/js/validaciones.js
```

## 2. Instalación en CentOS Stream 10

### 2.1 PostgreSQL
```bash
sudo dnf install -y postgresql-server postgresql-contrib python3 python3-pip
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```
`postgresql-contrib` es necesario: trae **pgcrypto** (hash bcrypt de las contraseñas).

Para que Flask entre con usuario y contraseña, en `/var/lib/pgsql/data/pg_hba.conf`
cambia `ident` por `scram-sha-256` en las líneas `host` de `127.0.0.1/32` y `::1/128`:
```
host    all    all    127.0.0.1/32    scram-sha-256
host    all    all    ::1/128         scram-sha-256
```
```bash
sudo systemctl reload postgresql
```

### 2.2 Base de datos (en este orden)
Desde la carpeta `db/`. Se usa `<` para que el usuario postgres no necesite permiso sobre tu carpeta
(si aparece *could not change directory... Permission denied*, es solo un aviso).
```bash
cd db
sudo -u postgres psql -v app_password='TuClaveSegura' < 01_schema_banco_sangre_organos.sql
sudo -u postgres psql < 02_inserts_banco_sangre_organos.sql > /dev/null
sudo -u postgres psql < 03_funciones.sql
sudo -u postgres psql < 04_procedimientos.sql
sudo -u postgres psql < 05_vistas.sql
sudo -u postgres psql < 06_consultas.sql > 06_resultado_consultas.txt     # evidencia de las consultas
```
- `01` crea el usuario `app_banco` (con la contraseña que le pases), la base
  `banco_sangre_organos` (si ya existía la **borra y la vuelve a crear**) y las tablas.
  `app_banco` solo puede leer/escribir datos, no borrar tablas.
- Opcional: `sudo -u postgres psql < 07_pruebas_procedimientos.sql > 07_resultado_pruebas.txt 2>&1`
  (agrega datos; después vuelve a correr 01 a 05 para dejar la base limpia).

### 2.3 Aplicación
Instalar (una sola vez):
```bash
cd ..                       # carpeta red_salud_app
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```
Correrla (cada vez que la quieras usar; se apaga con Ctrl + C o al cerrar la terminal):
```bash
cd red_salud_app
source venv/bin/activate
export FLASK_APP=app.py
export DB_HOST=localhost DB_NAME=banco_sangre_organos DB_USER=app_banco
export DB_PASSWORD='TuClaveSegura'
flask run --host=0.0.0.0 --port=8000
```
Abrir `http://IP_DEL_SERVIDOR:8000` (el puerto 8000 debe estar abierto en el firewall).
Sin espacios alrededor del `=` en los `export`. La contraseña de la base **no** está en el código:
`app.py` la lee de `DB_PASSWORD`.

## 3. Usuarios de prueba (contraseña `Demo2026!`)
| Usuario | Rol | Institución |
|---|---|---|
| `jcruz` | Administrador del sistema | Centro Estatal de Transfusión Sanguínea |
| `tmedina` | Coordinador regional | Centro Estatal de Transfusión Sanguínea |
| `agomez` | Laboratorio | Centro Estatal de Transfusión Sanguínea |
| `gortiz` | Logística / transporte | Centro Estatal de Transfusión Sanguínea |
| `eesquivel` | Personal médico | Centro Estatal de Transfusión Sanguínea |
| `rreyes` | Coordinador hospitalario y Personal médico | Hospital Universitario |
| `atamez` | Coordinador hospitalario | Hospital Cumbres del Valle |
| `iibarra` | Personal médico | Hospital Cumbres del Valle |

`lgomez` (Bloqueado) y `crodriguez` (Inactivo) no pueden entrar.

## 4. Cómo se cumple cada requisito
**Autenticación:** `sp_validar_login` compara la contraseña contra el hash bcrypt (pgcrypto); los usuarios nuevos se
guardan con `crypt(..., gen_salt('bf'))` dentro de `sp_crear_usuario`. Cada ruta revisa la sesión (sin sesión
redirige al login) y el permiso del rol (sin permiso responde 403), y los procedimientos vuelven a revisar el permiso
con `fn_tiene_permiso`.

**CRUD (equivalencias de Pacientes / Médicos / Consultas):**
| Entidad | Crear | Consultar | Modificar | Eliminar |
|---|---|---|---|---|
| Donantes (`/donantes`) | `sp_registrar_donante` | lista con búsqueda y filtros + detalle con historial | `sp_actualizar_donante` | `sp_eliminar_donante`: físico si no tiene historial; si tiene, baja lógica (Inactivo) |
| Personal (`/personal`) | `sp_registrar_personal` (+ `sp_crear_usuario` con hash) | lista con filtros (LEFT JOIN usuarios) + detalle | `sp_actualizar_personal` | `sp_eliminar_personal`: físico si no tiene registros; si tiene, baja lógica |
| Solicitudes (`/solicitudes`) | `sp_registrar_solicitud_sangre` / `_organo` | lista con filtros + detalle (vista_matching) | `sp_actualizar_solicitud` | `sp_cancelar_solicitud` (baja lógica: queda Cancelada) |

**Procedimientos desde Flask:** los 41. `app.py` no tiene SQL directo: cada pantalla hace `CALL sp_...` y, para
leer, `FETCH ALL FROM cursor_...` (procedimientos con parámetro OUT REFCURSOR).

**Vistas en Flask** (a través de procedimientos): `vista_inventario_proximo_a_caducar` y
`vista_hospitales_solicitudes_activas` (Inicio, `sp_obtener_inicio`), `vista_inventario_sangre` (Inventario),
`vista_matching` (detalle de solicitud), `vista_traslados` (Traslados).

**Consultas en Flask:** CROSS JOIN de inventario bajo mínimo (Inicio), LEFT JOIN personal-usuarios (Personal),
CTE de aprovechamiento y funciones de ventana (Reportes).

**Validaciones:** JavaScript (`static/js/validaciones.js`) y otra vez en el servidor (procedimientos +
restricciones de las tablas). Mensajes de éxito/error en la página (`?ok=` / `?error=` al redirigir). Errores de conexión o de base de datos muestran una
página de error. Todas las consultas son parametrizadas y cada operación es una transacción (COMMIT/ROLLBACK).
