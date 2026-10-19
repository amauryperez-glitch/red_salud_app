# Red de Salud · Flask + PostgreSQL

Aplicación web para la red regional de bancos de sangre y donación de órganos.

## 1. Estructura

```
app.py                                   rutas de Flask (configuración por variables de entorno)
requirements.txt                         Flask, psycopg 3, gunicorn
db/01_schema_banco_sangre_organos.sql    CREATE ROLE + CREATE DATABASE + tablas + índices
db/02_inserts_banco_sangre_organos.sql   datos de prueba (contraseñas con hash bcrypt)
db/03_funciones.sql                      8 funciones de apoyo (no cuentan como procedimientos)
db/04_procedimientos.sql                 16 procedimientos almacenados documentados (CALL)
db/05_vistas.sql                         5 vistas
db/06_consultas.sql                      consultas con JOIN y complementarias (solo lectura)
db/07_pruebas_procedimientos.sql         pruebas de los procedimientos (opcional, agrega datos)
db/07_resultado_pruebas.txt              resultado obtenido de esas pruebas
templates/                               pantallas (Jinja2, base.html + una por módulo)
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
```bash
cd ..                       # carpeta red_salud_app
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

export DB_HOST=localhost DB_PORT=5432 DB_NAME=banco_sangre_organos DB_USER=app_banco
export DB_PASSWORD='TuClaveSegura'
export SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"

python app.py                                  # prueba local: http://127.0.0.1:5000
gunicorn -w 2 -b 0.0.0.0:8000 app:app          # servidor: http://IP_DEL_SERVIDOR:8000
sudo firewall-cmd --add-port=8000/tcp --permanent && sudo firewall-cmd --reload
```
Las contraseñas **no** están en el código ni en el repositorio: se leen de las variables de entorno.
Con varios workers de gunicorn, `SECRET_KEY` debe ser la misma para todos (exportarla antes, como arriba).

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
guardan con `crypt(..., gen_salt('bf'))`. Sesión de Flask con cookie HttpOnly. Cada ruta tiene `@login_requerido` o
`@permiso_requerido(...)` (sin sesión redirige al login; sin permiso responde 403) y los procedimientos vuelven a
revisar el permiso con `fn_tiene_permiso`.

**CRUD (equivalencias de Pacientes / Médicos / Consultas):**
| Entidad | Crear | Consultar | Modificar | Eliminar |
|---|---|---|---|---|
| Donantes (`/donantes`) | `sp_registrar_donante` | lista con búsqueda y filtros + detalle con historial | datos, teléfono, tipo (si no ha donado), estado | físico si no tiene historial; si tiene donaciones, baja lógica (Inactivo) |
| Personal (`/personal`) | persona + personal (+ usuario con hash) | lista con filtros (LEFT JOIN usuarios) + detalle | datos, institución, cargo, cédula, estado | físico si no tiene registros; si tiene, baja lógica (personal y usuario Inactivos) |
| Solicitudes (`/solicitudes`) | `sp_registrar_solicitud_sangre` / `_organo` | lista con filtros + detalle (vista_matching) | urgencia, fecha límite, motivo, observaciones | `sp_cancelar_solicitud` (baja lógica: queda Cancelada) |

**Procedimientos desde Flask:** los 16 (login, donante, donación, laboratorio, fraccionar, matching, solicitudes de
sangre y órgano, asignar, traslado, recepción, transfusión, descarte, órgano, trasplante, cancelar).

**Vistas en Flask:** `vista_inventario_proximo_a_caducar` y `vista_hospitales_solicitudes_activas` (Inicio),
`vista_inventario_sangre` (Inventario), `vista_matching` (detalle de solicitud), `vista_traslados` (Traslados).

**Consultas en Flask:** CROSS JOIN de inventario bajo mínimo (Inicio), LEFT JOIN personal-usuarios (Personal),
CTE de aprovechamiento y funciones de ventana (Reportes).

**Validaciones:** JavaScript (`static/js/validaciones.js`) y otra vez en el servidor (app.py + procedimientos +
restricciones de las tablas). Mensajes de éxito/error con `flash`. Errores de conexión o de base de datos muestran una
página de error. Todas las consultas son parametrizadas y cada operación es una transacción (COMMIT/ROLLBACK).
