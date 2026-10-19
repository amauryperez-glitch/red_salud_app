"""
Red de Salud - Bancos de sangre y donación de órganos
Flask + PostgreSQL (psycopg 3)

La conexión se configura con variables de entorno (no hay contraseñas en el código):
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, SECRET_KEY
"""
import os
import re
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from functools import wraps

import psycopg
from psycopg.rows import dict_row, tuple_row
from flask import Flask, render_template, request, redirect, url_for, session, flash, abort

app = Flask(__name__)

# ======================================================
# CONFIGURACIÓN
# ======================================================
app.config.update(
    SECRET_KEY=os.environ.get('SECRET_KEY') or os.urandom(32),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',
    PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
)
if not os.environ.get('SECRET_KEY'):
    app.logger.warning('SECRET_KEY no está definida: las sesiones se pierden al reiniciar la aplicación')

DB = {
    'host': os.environ.get('DB_HOST', 'localhost'),
    'port': os.environ.get('DB_PORT', '5432'),
    'dbname': os.environ.get('DB_NAME', 'banco_sangre_organos'),
    'user': os.environ.get('DB_USER', 'app_banco'),
    'password': os.environ.get('DB_PASSWORD', ''),
}

RE_CORREO = re.compile(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
RE_TELEFONO = re.compile(r'^[0-9]{10,15}$')
RE_LOGIN = re.compile(r'^[a-z0-9._]{4,50}$')

# errores que regresan los procedimientos y restricciones (se muestran al usuario como mensaje)
ERRORES_SP = (psycopg.errors.RaiseException, psycopg.IntegrityError, psycopg.DataError)


# ======================================================
# BASE DE DATOS
# ======================================================
def conectar():
    """Conexión nueva con filas como diccionario y la hora de Monterrey.
    Usada con 'with': hace COMMIT si todo sale bien y ROLLBACK si hay excepción."""
    return psycopg.connect(**DB, row_factory=dict_row, connect_timeout=5,
                           options='-c timezone=America/Monterrey')


def consultar(sql, params=None):
    with conectar() as cn:
        return cn.execute(sql, params).fetchall()


def consultar_uno(sql, params=None):
    with conectar() as cn:
        return cn.execute(sql, params).fetchone()


def llamar(sql, params):
    """Ejecuta un CALL a un procedimiento almacenado y regresa sus parámetros OUT (o None)."""
    with conectar() as cn:
        cur = cn.execute(sql, params)
        return cur.fetchone() if cur.description else None


def mensaje_error(e):
    """Mensaje del RAISE EXCEPTION del procedimiento (o de la restricción que falló)."""
    diag = getattr(e, 'diag', None)
    if diag is not None and diag.message_primary:
        return diag.message_primary
    return str(e).split('\n')[0]


# catálogos para llenar los <select> (consultas fijas, sin datos del usuario)
SQL_CATALOGOS = {
    'tipos_sangre': "SELECT id_tipo_sanguineo AS id, nombre FROM cat_tipos_sanguineo ORDER BY 1",
    'sexos': "SELECT id_sexo AS id, nombre FROM cat_sexo ORDER BY 1",
    'estados_donante': "SELECT id_estado_donante AS id, nombre FROM cat_estados_donante ORDER BY 1",
    'estados_receptor': "SELECT id_estado_receptor AS id, nombre FROM cat_estados_receptor ORDER BY 1",
    'estados_personal': "SELECT id_estado_personal AS id, nombre FROM cat_estados_personal ORDER BY 1",
    'estados_solicitud': "SELECT id_estado_solicitud AS id, nombre FROM cat_estados_solicitud ORDER BY 1",
    'estados_donacion': "SELECT id_estado_donacion AS id, nombre FROM cat_estados_donacion ORDER BY 1",
    'estados_recurso': "SELECT id_estado_recurso AS id, nombre FROM cat_estados_recurso ORDER BY 1",
    'estados_traslado': "SELECT id_estado_traslado AS id, nombre FROM cat_estados_traslado ORDER BY 1",
    'cargos': "SELECT id_cargo AS id, nombre FROM cat_cargos ORDER BY 2",
    'roles': "SELECT id_rol AS id, nombre FROM cat_roles ORDER BY 1",
    'instituciones': "SELECT id_institucion AS id, nombre FROM instituciones ORDER BY 2",
    'instituciones_activas': "SELECT id_institucion AS id, nombre FROM instituciones WHERE id_estado_institucion = 1 ORDER BY 2",
    'componentes': "SELECT id_componente AS id, nombre FROM cat_componentes_sangre ORDER BY 1",
    'urgencias': "SELECT id_urgencia AS id, nombre FROM cat_urgencias ORDER BY peso DESC",
    'tipos_organo': "SELECT id_tipo_organo AS id, nombre FROM cat_organos ORDER BY 1",
    'lados': "SELECT id_lado_organo AS id, nombre FROM cat_lados_organo ORDER BY 1",
    'tipos_evaluacion': "SELECT id_tipo_evaluacion AS id, nombre FROM cat_tipos_evaluacion ORDER BY 1",
    'resultados_evaluacion': "SELECT id_resultado_evaluacion AS id, nombre FROM cat_resultados_evaluacion ORDER BY 1",
    'causas_descarte': "SELECT id_causa_descarte AS id, nombre FROM cat_causas_descarte ORDER BY 1",
    'medios_transporte': "SELECT id_medio_transporte AS id, nombre FROM cat_medios_transporte ORDER BY 1",
    'resultados_recepcion': "SELECT id_resultado_recepcion AS id, nombre FROM cat_resultados_recepcion ORDER BY 1",
    'resultados_transfusion': "SELECT id_resultado_transfusion AS id, nombre FROM cat_resultados_transfusion ORDER BY 1",
    'receptores': """SELECT r.id_receptor AS id, p.nombres || ' ' || p.apellidos || ' (' || ts.nombre || ')' AS nombre
                     FROM receptores r JOIN personas p ON p.id_persona = r.id_persona
                     JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
                     WHERE r.id_estado_receptor <> 2 ORDER BY 2""",
    'donantes_activos': """SELECT d.id_donante AS id, d.id_donante || ' - ' || p.nombres || ' ' || p.apellidos || ' (' || ts.nombre || ')' AS nombre
                           FROM donantes d JOIN personas p ON p.id_persona = d.id_persona
                           JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = d.id_tipo_sanguineo
                           WHERE d.id_estado_donante = 1 ORDER BY p.nombres, p.apellidos""",
    'donantes_organo': """SELECT d.id_donante AS id, d.id_donante || ' - ' || p.nombres || ' ' || p.apellidos || ' (' || ts.nombre || ')' AS nombre
                          FROM donantes d JOIN personas p ON p.id_persona = d.id_persona
                          JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = d.id_tipo_sanguineo
                          WHERE d.id_estado_donante <> 2 ORDER BY p.nombres, p.apellidos""",
}


def catalogos(*nombres):
    with conectar() as cn:
        return {n: cn.execute(SQL_CATALOGOS[n]).fetchall() for n in nombres}


# ======================================================
# SESIÓN Y PERMISOS (se verifican en el servidor en cada ruta)
# ======================================================
def tiene(*permisos):
    """¿El usuario tiene alguno de estos permisos? (vienen de rol_permiso al iniciar sesión)"""
    actuales = session.get('permisos', [])
    return any(p in actuales for p in permisos)


def login_requerido(vista):
    @wraps(vista)
    def envoltura(*args, **kwargs):
        if 'id_usuario' not in session:
            flash('Inicia sesión para continuar.', 'error')
            return redirect(url_for('principal', next=request.path))
        return vista(*args, **kwargs)
    return envoltura


def permiso_requerido(*permisos):
    """Bloquea la ruta si el rol no tiene ninguno de los permisos indicados (HTTP 403)."""
    def decorador(vista):
        @wraps(vista)
        @login_requerido
        def envoltura(*args, **kwargs):
            if not tiene(*permisos):
                return render_template('error.html', titulo='Acceso denegado',
                                       mensaje='Tu rol (' + session.get('roles', '') +
                                               ') no tiene permiso para esta operación.'), 403
            return vista(*args, **kwargs)
        return envoltura
    return decorador


def ve_toda_la_red():
    return tiene('Consultar reportes regionales')


@app.context_processor
def utilidades_plantillas():
    return {'tiene': tiene}


@app.template_filter('fecha')
def filtro_fecha(valor):
    return valor.strftime('%d/%m/%Y') if valor else ''


@app.template_filter('fechahora')
def filtro_fechahora(valor):
    return valor.strftime('%d/%m/%Y %H:%M') if valor else ''


@app.template_filter('clase')
def filtro_clase(valor):
    """'En traslado' -> 'en-traslado' (para el color de las etiquetas)"""
    return (valor or '').lower().replace(' ', '-')


# ======================================================
# VALIDACIONES DEL LADO DEL SERVIDOR
# ======================================================
def entero(valor, defecto=None):
    try:
        return int(valor)
    except (TypeError, ValueError):
        return defecto


def numero(valor):
    """Número con decimales (Decimal para que PostgreSQL lo reciba como NUMERIC). '' -> None."""
    if valor in (None, ''):
        return None
    try:
        d = Decimal(valor)
    except InvalidOperation:
        return 'error'
    return d if d.is_finite() else 'error'


def calcular_edad(nacimiento):
    hoy = date.today()
    return hoy.year - nacimiento.year - ((hoy.month, hoy.day) < (nacimiento.month, nacimiento.day))


def leer_persona(errores, edad_min=0, edad_max=120, revisar_edad=True):
    """Lee y valida los datos de persona del formulario."""
    f = request.form
    d = {
        'nombres': f.get('nombres', '').strip(),
        'apellidos': f.get('apellidos', '').strip(),
        'id_sexo': entero(f.get('id_sexo')),
        'correo': f.get('correo', '').strip().lower() or None,
        'telefono': f.get('telefono', '').strip() or None,
        'fecha_nacimiento': None,
    }
    if not d['nombres'] or len(d['nombres']) > 100:
        errores.append('Escribe los nombres (máximo 100 caracteres).')
    if not d['apellidos'] or len(d['apellidos']) > 100:
        errores.append('Escribe los apellidos (máximo 100 caracteres).')
    if d['id_sexo'] is None:
        errores.append('Selecciona el sexo.')
    try:
        d['fecha_nacimiento'] = date.fromisoformat(f.get('fecha_nacimiento', ''))
    except ValueError:
        errores.append('La fecha de nacimiento no es válida.')
    if d['fecha_nacimiento']:
        if d['fecha_nacimiento'] > date.today():
            errores.append('La fecha de nacimiento no puede ser futura.')
        elif d['fecha_nacimiento'] < date(1900, 1, 1):
            errores.append('La fecha de nacimiento no es válida.')
        elif revisar_edad:
            edad = calcular_edad(d['fecha_nacimiento'])
            if edad < edad_min or edad > edad_max:
                errores.append('La edad debe estar entre %d y %d años (tiene %d).' % (edad_min, edad_max, edad))
    if d['correo'] and (len(d['correo']) > 150 or not RE_CORREO.match(d['correo'])):
        errores.append('El correo no tiene un formato válido.')
    if d['telefono'] and not RE_TELEFONO.match(d['telefono']):
        errores.append('El teléfono debe tener de 10 a 15 dígitos, sin espacios ni guiones.')
    return d


def mensaje_restriccion(e):
    """Traduce violaciones de restricciones a mensajes para el usuario."""
    nombre = getattr(getattr(e, 'diag', None), 'constraint_name', '') or ''
    if 'correo' in nombre:
        return 'Ya existe una persona registrada con ese correo.'
    if 'telefono' in nombre:
        return 'El teléfono no es válido o ya está registrado para esa persona.'
    if 'cedula' in nombre:
        return 'Ya existe personal con esa cédula profesional.'
    if 'usuario_login' in nombre:
        return 'Ese nombre de usuario ya existe.'
    return 'Los datos no cumplen las reglas de la base de datos: ' + mensaje_error(e)


def mostrar_errores(errores):
    for e in errores:
        flash(e, 'error')


def regresar(defecto):
    """Regresa a la página desde donde se envió el formulario (solo rutas internas)."""
    destino = request.form.get('regresar', '')
    if destino.startswith('/') and not destino.startswith('//'):
        return redirect(destino)
    return redirect(defecto)


# ======================================================
# MANEJO DE ERRORES
# ======================================================
@app.errorhandler(psycopg.OperationalError)
def error_conexion(e):
    app.logger.error('Error de conexión con PostgreSQL: %s', e)
    return render_template('error.html', titulo='Sin conexión con la base de datos',
                           mensaje='No fue posible conectarse a PostgreSQL. Intenta de nuevo en unos minutos.'), 503


@app.errorhandler(psycopg.Error)
def error_base_datos(e):
    app.logger.error('Error de base de datos: %s', e)
    return render_template('error.html', titulo='Error en la base de datos',
                           mensaje='La operación no se pudo completar: ' + mensaje_error(e)), 500


@app.errorhandler(404)
def no_encontrado(e):
    return render_template('error.html', titulo='No encontrado',
                           mensaje='La página o el registro que buscas no existe.'), 404


@app.errorhandler(405)
def metodo_no_permitido(e):
    return render_template('error.html', titulo='Operación no permitida',
                           mensaje='Esta dirección no acepta ese tipo de solicitud.'), 405


# ======================================================
# AUTENTICACIÓN
# ======================================================
@app.route('/')
def principal():
    if 'id_usuario' in session:
        return redirect(url_for('inicio'))
    return render_template('login.html', siguiente=request.args.get('next', ''))


@app.route('/login', methods=['POST'])
def login():
    usuario = request.form.get('usuario', '').strip().lower()
    password = request.form.get('password', '')
    siguiente = request.form.get('next', '')

    if not usuario or not password:
        flash('Escribe tu usuario y tu contraseña.', 'error')
        return redirect(url_for('principal'))

    # SP1: valida usuario + hash bcrypt de la contraseña en PostgreSQL
    with conectar() as cn:
        cur = cn.cursor(row_factory=tuple_row)   # el cursor trae columnas con el mismo nombre
        cur.execute("CALL sp_validar_login(%s, %s, NULL)", (usuario, password))
        fila = cur.execute("FETCH ALL FROM cursor_login").fetchone()

    if fila is None:
        flash('Usuario o contraseña incorrectos, o la cuenta no está activa.', 'error')
        return redirect(url_for('principal'))

    valores = fila
    session.clear()
    session.permanent = True
    session['id_usuario'] = valores[0]
    session['id_personal'] = valores[1]
    session['nombre'] = valores[2]
    session['cargo'] = valores[3]
    session['id_institucion'] = valores[4]
    session['institucion'] = valores[5]
    session['roles'] = valores[6] or ''
    session['permisos'] = valores[7].split(';') if valores[7] else []
    session['tipo_institucion'] = valores[8]
    session['servicios'] = valores[9].split(';') if valores[9] else []

    if siguiente.startswith('/') and not siguiente.startswith('//'):
        return redirect(siguiente)
    return redirect(url_for('inicio'))


@app.route('/salir')
def salir():
    session.clear()
    flash('Sesión cerrada.', 'ok')
    return redirect(url_for('principal'))


@app.route('/inicio')
@login_requerido
def inicio():
    proximos = bajo_minimo = activas = None

    if tiene('Consultar inventario y alertas'):
        # vista_inventario_proximo_a_caducar
        proximos = consultar("SELECT * FROM vista_inventario_proximo_a_caducar")
        # CROSS JOIN banco x componente contra su mínimo (consulta 5 de 06_consultas.sql)
        bajo_minimo = consultar("""
            SELECT * FROM (
                SELECT b.nombre AS banco_sangre, c.nombre AS componente,
                       count(r.id_recurso) AS disponibles, ui.minimo
                FROM instituciones b
                CROSS JOIN cat_componentes_sangre c
                LEFT JOIN unidades_componentes_sanguineos u ON u.id_componente = c.id_componente
                LEFT JOIN recursos r ON r.id_recurso = u.id_recurso
                                    AND r.id_institucion = b.id_institucion
                                    AND r.id_estado_recurso = 1
                LEFT JOIN umbrales_inventario ui ON ui.id_institucion = b.id_institucion
                                                AND ui.id_componente = c.id_componente AND ui.activo
                WHERE b.id_tipo_institucion = 1
                GROUP BY b.nombre, c.nombre, ui.minimo
            ) x
            WHERE disponibles < minimo
            ORDER BY banco_sangre, componente""")

    if ve_toda_la_red():
        activas = consultar("SELECT * FROM vista_hospitales_solicitudes_activas")
    elif tiene('Registrar solicitudes', 'Consultar compatibilidad'):
        activas = consultar("SELECT * FROM vista_hospitales_solicitudes_activas WHERE id_hospital = %s",
                            (session['id_institucion'],))

    return render_template('inicio.html', proximos=proximos, bajo_minimo=bajo_minimo, activas=activas)


# ======================================================
# CRUD 1: DONANTES
# ======================================================
@app.route('/donantes')
@permiso_requerido('Registrar donaciones')
def donantes():
    q = request.args.get('q', '').strip()
    tipo = entero(request.args.get('tipo'), 0)
    estado = entero(request.args.get('estado'), 0)
    lista = consultar("""
        SELECT d.id_donante, p.nombres || ' ' || p.apellidos AS nombre, ts.nombre AS tipo_sangre,
               fn_calcular_edad(p.fecha_nacimiento) AS edad, ed.nombre AS estado, p.correo,
               (SELECT max(dn.fecha_hora_inicio) FROM donaciones dn WHERE dn.id_donante = d.id_donante) AS ultima
        FROM donantes d
        JOIN personas p ON p.id_persona = d.id_persona
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = d.id_tipo_sanguineo
        JOIN cat_estados_donante ed ON ed.id_estado_donante = d.id_estado_donante
        WHERE (%(q)s = '' OR p.nombres || ' ' || p.apellidos ILIKE %(patron)s OR d.id_donante::text = %(q)s)
          AND (%(tipo)s = 0 OR d.id_tipo_sanguineo = %(tipo)s)
          AND (%(estado)s = 0 OR d.id_estado_donante = %(estado)s)
        ORDER BY d.id_donante DESC
    """, {'q': q, 'patron': '%' + q + '%', 'tipo': tipo, 'estado': estado})
    return render_template('donantes.html', donantes=lista, q=q, tipo=tipo, estado=estado,
                           **catalogos('tipos_sangre', 'estados_donante'))


@app.route('/donantes/nuevo', methods=['GET', 'POST'])
@permiso_requerido('Registrar donaciones')
def donante_nuevo():
    if request.method == 'POST':
        errores = []
        d = leer_persona(errores, 18, 65)
        tipo = entero(request.form.get('id_tipo_sanguineo'))
        if tipo is None:
            errores.append('Selecciona el tipo sanguíneo.')
        if not errores:
            try:
                # SP2
                fila = llamar("CALL sp_registrar_donante(%s,%s,%s,%s,%s,%s,%s,%s,NULL)",
                              (d['nombres'], d['apellidos'], d['fecha_nacimiento'], d['id_sexo'],
                               d['correo'], d['telefono'], tipo, session['id_personal']))
                flash('Donante registrado con id %s.' % fila['p_id_donante'], 'ok')
                return redirect(url_for('donante_detalle', id_donante=fila['p_id_donante']))
            except ERRORES_SP as e:
                errores.append(mensaje_error(e))
        mostrar_errores(errores)
    return render_template('donante_form.html', donante=None, valores=request.form,
                           **catalogos('tipos_sangre', 'sexos', 'estados_donante'))


@app.route('/donantes/<int:id_donante>')
@permiso_requerido('Registrar donaciones')
def donante_detalle(id_donante):
    with conectar() as cn:
        donante = cn.execute("""
            SELECT d.id_donante, d.id_persona, p.nombres, p.apellidos, p.fecha_nacimiento, p.correo,
                   fn_calcular_edad(p.fecha_nacimiento) AS edad, sx.nombre AS sexo,
                   ts.nombre AS tipo_sangre, ed.nombre AS estado
            FROM donantes d
            JOIN personas p ON p.id_persona = d.id_persona
            JOIN cat_sexo sx ON sx.id_sexo = p.id_sexo
            JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = d.id_tipo_sanguineo
            JOIN cat_estados_donante ed ON ed.id_estado_donante = d.id_estado_donante
            WHERE d.id_donante = %s""", (id_donante,)).fetchone()
        if donante is None:
            abort(404)
        telefonos = cn.execute("""SELECT t.telefono, tt.nombre AS tipo FROM telefonos t
                                  JOIN cat_tipos_telefono tt ON tt.id_tipo_telefono = t.id_tipo_telefono
                                  WHERE t.id_persona = %s ORDER BY t.id_telefono""",
                               (donante['id_persona'],)).fetchall()
        historial = cn.execute("""
            SELECT dn.id_donacion, dn.fecha_hora_inicio, td.nombre AS tipo, i.nombre AS institucion,
                   dn.volumen_ml, ed.nombre AS estado,
                   (SELECT count(*) FROM unidades_componentes_sanguineos u WHERE u.id_donacion = dn.id_donacion) AS unidades
            FROM donaciones dn
            JOIN cat_tipos_donacion td ON td.id_tipo_donacion = dn.id_tipo_donacion
            JOIN instituciones i ON i.id_institucion = dn.id_institucion
            JOIN cat_estados_donacion ed ON ed.id_estado_donacion = dn.id_estado_donacion
            WHERE dn.id_donante = %s ORDER BY dn.fecha_hora_inicio DESC""", (id_donante,)).fetchall()
        organos = cn.execute("""
            SELECT r.folio, co.nombre AS organo, op.fecha_hora, er.nombre AS estado
            FROM organos o
            JOIN operaciones op ON op.id_operacion = o.id_extraccion
            JOIN recursos r ON r.id_recurso = o.id_recurso
            JOIN cat_organos co ON co.id_tipo_organo = o.id_tipo_organo
            JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
            WHERE op.id_persona = %s ORDER BY op.fecha_hora DESC""", (donante['id_persona'],)).fetchall()
    return render_template('donante_detalle.html', donante=donante, telefonos=telefonos,
                           historial=historial, organos=organos)


@app.route('/donantes/<int:id_donante>/editar', methods=['GET', 'POST'])
@permiso_requerido('Registrar donaciones')
def donante_editar(id_donante):
    actual = consultar_uno("""
        SELECT d.id_donante, d.id_persona, d.id_tipo_sanguineo, d.id_estado_donante,
               p.nombres, p.apellidos, p.fecha_nacimiento, p.id_sexo, p.correo,
               (SELECT t.telefono FROM telefonos t WHERE t.id_persona = d.id_persona ORDER BY t.id_telefono LIMIT 1) AS telefono,
               (SELECT count(*) FROM donaciones dn WHERE dn.id_donante = d.id_donante) AS donaciones
        FROM donantes d JOIN personas p ON p.id_persona = d.id_persona
        WHERE d.id_donante = %s""", (id_donante,))
    if actual is None:
        abort(404)

    if request.method == 'POST':
        errores = []
        cambio_fecha = request.form.get('fecha_nacimiento') != str(actual['fecha_nacimiento'])
        d = leer_persona(errores, 18, 65, revisar_edad=cambio_fecha)
        tipo = entero(request.form.get('id_tipo_sanguineo'))
        estado = entero(request.form.get('id_estado_donante'))
        if tipo is None or estado is None:
            errores.append('Selecciona el tipo sanguíneo y el estado.')
        # reglas de negocio
        if tipo != actual['id_tipo_sanguineo'] and actual['donaciones'] > 0:
            errores.append('No se puede cambiar el tipo sanguíneo: el donante ya tiene donaciones '
                           'y sus unidades se etiquetaron con ese tipo.')
        if actual['id_estado_donante'] == 4 and estado != 4:
            errores.append('Un donante registrado como Fallecido no puede cambiar de estado.')

        if not errores:
            try:
                with conectar() as cn:
                    cn.execute("""UPDATE personas SET nombres = %s, apellidos = %s, fecha_nacimiento = %s,
                                  id_sexo = %s, correo = %s WHERE id_persona = %s""",
                               (d['nombres'], d['apellidos'], d['fecha_nacimiento'], d['id_sexo'],
                                d['correo'], actual['id_persona']))
                    actualizar_telefono(cn, actual['id_persona'], actual['telefono'], d['telefono'], 1)
                    cn.execute("UPDATE donantes SET id_tipo_sanguineo = %s, id_estado_donante = %s WHERE id_donante = %s",
                               (tipo, estado, id_donante))
                flash('Datos del donante actualizados.', 'ok')
                return redirect(url_for('donante_detalle', id_donante=id_donante))
            except (psycopg.errors.UniqueViolation, psycopg.errors.CheckViolation,
                    psycopg.errors.ForeignKeyViolation) as e:
                errores.append(mensaje_restriccion(e))
        mostrar_errores(errores)
        valores = request.form
    else:
        valores = actual
    return render_template('donante_form.html', donante=actual, valores=valores,
                           **catalogos('tipos_sangre', 'sexos', 'estados_donante'))


def actualizar_telefono(cn, id_persona, anterior, nuevo, tipo_telefono):
    """Mantiene el teléfono principal de la persona (el primero registrado)."""
    if nuevo == anterior:
        return
    if anterior and nuevo:
        cn.execute("UPDATE telefonos SET telefono = %s WHERE id_persona = %s AND telefono = %s",
                   (nuevo, id_persona, anterior))
    elif anterior and not nuevo:
        cn.execute("DELETE FROM telefonos WHERE id_persona = %s AND telefono = %s", (id_persona, anterior))
    else:
        cn.execute("INSERT INTO telefonos (id_persona, telefono, id_tipo_telefono) VALUES (%s, %s, %s)",
                   (id_persona, nuevo, tipo_telefono))


@app.route('/donantes/<int:id_donante>/eliminar', methods=['POST'])
@permiso_requerido('Registrar donaciones')
def donante_eliminar(id_donante):
    with conectar() as cn:
        fila = cn.execute("SELECT id_persona, id_estado_donante FROM donantes WHERE id_donante = %s",
                          (id_donante,)).fetchone()
        if fila is None:
            abort(404)
        try:
            # si tiene donaciones u órganos, la llave foránea lo impide
            with cn.transaction():
                cn.execute("DELETE FROM donantes WHERE id_donante = %s", (id_donante,))
            eliminado = True
        except psycopg.errors.ForeignKeyViolation:
            eliminado = False

        if eliminado:
            try:
                # la persona solo se borra si no es también personal, receptor, etc.
                with cn.transaction():
                    cn.execute("DELETE FROM telefonos WHERE id_persona = %s", (fila['id_persona'],))
                    cn.execute("DELETE FROM personas WHERE id_persona = %s", (fila['id_persona'],))
            except psycopg.errors.ForeignKeyViolation:
                pass
            flash('Donante %s eliminado (no tenía historial).' % id_donante, 'ok')
            return redirect(url_for('donantes'))

        if fila['id_estado_donante'] == 2:
            flash('El donante ya estaba Inactivo.', 'info')
        else:
            cn.execute("UPDATE donantes SET id_estado_donante = 2 WHERE id_donante = %s", (id_donante,))
            flash('El donante tiene historial de donaciones: para no perderlo no se borra, '
                  'se dio de baja lógica (estado Inactivo).', 'ok')
    return redirect(url_for('donante_detalle', id_donante=id_donante))


# ======================================================
# RECEPTORES
# ======================================================
@app.route('/receptores', methods=['GET', 'POST'])
@permiso_requerido('Registrar solicitudes')
def receptores():
    if request.method == 'POST':
        errores = []
        d = leer_persona(errores, 0, 120)
        tipo = entero(request.form.get('id_tipo_sanguineo'))
        if tipo is None:
            errores.append('Selecciona el tipo sanguíneo.')
        if not errores:
            try:
                with conectar() as cn:
                    id_persona = cn.execute("""INSERT INTO personas (id_sexo, nombres, apellidos, fecha_nacimiento, correo)
                                               VALUES (%s, %s, %s, %s, %s) RETURNING id_persona""",
                                            (d['id_sexo'], d['nombres'], d['apellidos'],
                                             d['fecha_nacimiento'], d['correo'])).fetchone()['id_persona']
                    if d['telefono']:
                        cn.execute("INSERT INTO telefonos (id_persona, telefono, id_tipo_telefono) VALUES (%s, %s, 1)",
                                   (id_persona, d['telefono']))
                    id_receptor = cn.execute("""INSERT INTO receptores (id_persona, id_tipo_sanguineo, id_estado_receptor)
                                                VALUES (%s, %s, 1) RETURNING id_receptor""",
                                             (id_persona, tipo)).fetchone()['id_receptor']
                flash('Receptor registrado con id %s.' % id_receptor, 'ok')
                return redirect(url_for('receptores'))
            except (psycopg.errors.UniqueViolation, psycopg.errors.CheckViolation,
                    psycopg.errors.ForeignKeyViolation) as e:
                errores.append(mensaje_restriccion(e))
        mostrar_errores(errores)

    q = request.args.get('q', '').strip()
    lista = consultar("""
        SELECT r.id_receptor, p.nombres || ' ' || p.apellidos AS nombre, ts.nombre AS tipo_sangre,
               fn_calcular_edad(p.fecha_nacimiento) AS edad, er.nombre AS estado, p.correo,
               (SELECT count(*) FROM solicitudes s WHERE s.id_receptor = r.id_receptor) AS solicitudes
        FROM receptores r
        JOIN personas p ON p.id_persona = r.id_persona
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
        JOIN cat_estados_receptor er ON er.id_estado_receptor = r.id_estado_receptor
        WHERE %(q)s = '' OR p.nombres || ' ' || p.apellidos ILIKE %(patron)s
        ORDER BY r.id_receptor DESC""", {'q': q, 'patron': '%' + q + '%'})
    return render_template('receptores.html', receptores=lista, q=q, valores=request.form,
                           **catalogos('tipos_sangre', 'sexos'))


# ======================================================
# DONACIONES Y LABORATORIO
# ======================================================
@app.route('/donaciones')
@permiso_requerido('Registrar donaciones', 'Validar resultados de laboratorio', 'Registrar estudios')
def donaciones():
    estado = entero(request.args.get('estado'), 0)
    lista = consultar("""
        SELECT dn.id_donacion, dn.id_donante, p.nombres || ' ' || p.apellidos AS donante, ts.nombre AS tipo_sangre,
               i.nombre AS institucion, dn.fecha_hora_inicio, dn.volumen_ml, ed.nombre AS estado
        FROM donaciones dn
        JOIN donantes d ON d.id_donante = dn.id_donante
        JOIN personas p ON p.id_persona = d.id_persona
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = d.id_tipo_sanguineo
        JOIN instituciones i ON i.id_institucion = dn.id_institucion
        JOIN cat_estados_donacion ed ON ed.id_estado_donacion = dn.id_estado_donacion
        WHERE dn.id_tipo_donacion = 1 AND (%(estado)s = 0 OR dn.id_estado_donacion = %(estado)s)
        ORDER BY dn.id_donacion DESC""", {'estado': estado})
    return render_template('donaciones.html', donaciones=lista, estado=estado,
                           **catalogos('estados_donacion', 'donantes_activos'))


@app.route('/donaciones/registrar', methods=['POST'])
@permiso_requerido('Registrar donaciones')
def donacion_registrar():
    id_donante = entero(request.form.get('id_donante'))
    volumen = entero(request.form.get('volumen_ml'))
    folio = request.form.get('folio_consentimiento', '').strip()
    obs = request.form.get('observaciones', '').strip() or None
    if id_donante is None or volumen is None or not folio:
        flash('Donante, volumen y folio del consentimiento son obligatorios.', 'error')
        return redirect(url_for('donaciones'))
    try:
        fila = llamar("CALL sp_registrar_donacion(%s,%s,%s,%s,%s,NULL)",      # SP3
                      (id_donante, session['id_personal'], volumen, folio, obs))
        flash('Donación %s registrada, queda Pendiente de laboratorio.' % fila['p_id_donacion'], 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('donaciones'))


@app.route('/donaciones/resultado', methods=['POST'])
@permiso_requerido('Validar resultados de laboratorio')
def donacion_resultado():
    id_donacion = entero(request.form.get('id_donacion'))
    valores = [request.form.get(c, '') for c in ('vih', 'hepatitis_b', 'hepatitis_c', 'sifilis')]
    if id_donacion is None or any(v not in ('Reactivo', 'No reactivo') for v in valores):
        flash('Cada resultado debe ser Reactivo o No reactivo.', 'error')
        return redirect(url_for('donaciones'))
    try:
        fila = llamar("CALL sp_registrar_resultado_laboratorio(%s,%s,%s,%s,%s,%s,NULL)",   # SP4
                      (id_donacion, session['id_personal'], *valores))
        flash('Donación %s: %s.' % (id_donacion, fila['p_resultado']), 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('donaciones'))


@app.route('/donaciones/fraccionar', methods=['POST'])
@permiso_requerido('Registrar estudios')
def donacion_fraccionar():
    id_donacion = entero(request.form.get('id_donacion'))
    try:
        fila = llamar("CALL sp_fraccionar_donacion(%s,%s,NULL)", (id_donacion, session['id_personal']))   # SP5
        flash('Se crearon %s unidades en el inventario.' % fila['p_total'], 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('donaciones'))


# ======================================================
# INVENTARIO (vista_inventario_sangre)
# ======================================================
@app.route('/inventario')
@permiso_requerido('Consultar inventario y alertas', 'Registrar descartes')
def inventario():
    filtros = {
        'banco': entero(request.args.get('banco'), 0),
        'tipo': request.args.get('tipo', ''),
        'componente': request.args.get('componente', ''),
        'estado': request.args.get('estado', ''),
    }
    with conectar() as cn:
        sangre = cn.execute("""
            SELECT v.*, fn_dias_restantes(v.id_recurso) AS dias
            FROM vista_inventario_sangre v
            WHERE (%(banco)s = 0 OR v.id_banco_sangre = %(banco)s)
              AND (%(tipo)s = '' OR v.tipo_sangre = %(tipo)s)
              AND (%(componente)s = '' OR v.componente = %(componente)s)
              AND ((%(estado)s = '' AND v.estado_recurso IN ('Disponible', 'Reservado', 'En traslado'))
                   OR v.estado_recurso = %(estado)s)
            ORDER BY v.fecha_caducidad""", filtros).fetchall()
        organos = cn.execute("""
            SELECT r.id_recurso, r.folio, co.nombre AS organo, ts.nombre AS tipo_sangre, i.nombre AS institucion,
                   er.nombre AS estado, vo.nombre AS viabilidad, o.fecha_hora_caducidad,
                   fn_dias_restantes(r.id_recurso) AS dias
            FROM organos o
            JOIN recursos r ON r.id_recurso = o.id_recurso
            JOIN cat_organos co ON co.id_tipo_organo = o.id_tipo_organo
            JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
            JOIN instituciones i ON i.id_institucion = r.id_institucion
            JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
            JOIN cat_viabilidad_organo vo ON vo.id_viabilidad_organo = o.id_viabilidad_organo
            WHERE r.id_estado_recurso IN (1, 2, 3)
            ORDER BY o.fecha_hora_caducidad""").fetchall()
    return render_template('inventario.html', sangre=sangre, organos=organos, f=filtros,
                           **catalogos('instituciones', 'tipos_sangre', 'componentes',
                                       'estados_recurso', 'causas_descarte'))


@app.route('/inventario/descartar', methods=['POST'])
@permiso_requerido('Registrar descartes')
def descartar():
    id_recurso = entero(request.form.get('id_recurso'))
    causa = entero(request.form.get('id_causa'))
    motivo = request.form.get('motivo', '').strip()
    if not motivo:
        flash('Escribe el motivo del descarte.', 'error')
        return regresar(url_for('inventario'))
    try:
        llamar("CALL sp_descartar_recurso(%s,%s,%s,%s)", (id_recurso, causa, session['id_personal'], motivo))  # SP12
        flash('Recurso %s descartado.' % id_recurso, 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return regresar(url_for('inventario'))


# ======================================================
# ÓRGANOS
# ======================================================
@app.route('/organos')
@permiso_requerido('Registrar evaluaciones de órganos')
def organos():
    lista = consultar("""
        SELECT r.id_recurso, r.folio, co.nombre AS organo, ts.nombre AS tipo_sangre, i.nombre AS institucion,
               er.nombre AS estado, vo.nombre AS viabilidad, o.fecha_hora_caducidad, o.tamano_cm,
               (SELECT re.nombre || ' (' || to_char(ev.fecha_hora, 'DD/MM/YYYY') || ')'
                FROM evaluaciones_organo ev
                JOIN cat_resultados_evaluacion re ON re.id_resultado_evaluacion = ev.id_resultado_evaluacion
                WHERE ev.id_recurso = r.id_recurso ORDER BY ev.fecha_hora DESC LIMIT 1) AS ultima_evaluacion
        FROM organos o
        JOIN recursos r ON r.id_recurso = o.id_recurso
        JOIN cat_organos co ON co.id_tipo_organo = o.id_tipo_organo
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
        JOIN instituciones i ON i.id_institucion = r.id_institucion
        JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
        JOIN cat_viabilidad_organo vo ON vo.id_viabilidad_organo = o.id_viabilidad_organo
        WHERE r.id_estado_recurso IN (1, 2, 3)
        ORDER BY o.fecha_hora_caducidad""")
    return render_template('organos.html', organos=lista,
                           **catalogos('tipos_evaluacion', 'resultados_evaluacion', 'tipos_organo',
                                       'lados', 'donantes_organo'))


@app.route('/organos/registrar', methods=['POST'])
@permiso_requerido('Registrar evaluaciones de órganos')
def organo_registrar():
    id_donante = entero(request.form.get('id_donante'))
    tipo = entero(request.form.get('id_tipo_organo'))
    lado = entero(request.form.get('id_lado'))
    peso = numero(request.form.get('peso_gramos'))
    tamano = numero(request.form.get('tamano_cm'))
    horas = entero(request.form.get('horas_viabilidad'))
    if id_donante is None or tipo is None or horas is None or 'error' in (peso, tamano):
        flash('Revisa los datos del órgano: donante, órgano y horas de viabilidad son obligatorios.', 'error')
        return redirect(url_for('organos'))
    try:
        fila = llamar("CALL sp_registrar_organo(%s,%s,%s,%s,%s,%s,%s,NULL)",       # SP13
                      (session['id_personal'], id_donante, tipo, lado, peso, tamano, horas))
        flash('Órgano registrado (recurso %s), queda En evaluación.' % fila['p_id_recurso'], 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('organos'))


@app.route('/organos/evaluar', methods=['POST'])
@permiso_requerido('Registrar evaluaciones de órganos')
def organo_evaluar():
    id_recurso = entero(request.form.get('id_recurso'))
    tipo = entero(request.form.get('id_tipo_evaluacion'))
    resultado = entero(request.form.get('id_resultado'))
    obs = request.form.get('observaciones', '').strip() or None
    with conectar() as cn:
        fila = cn.execute("""SELECT r.id_estado_recurso, fn_dias_restantes(r.id_recurso) AS dias
                             FROM organos o JOIN recursos r ON r.id_recurso = o.id_recurso
                             WHERE o.id_recurso = %s""", (id_recurso,)).fetchone()
        if fila is None:
            flash('El órgano no existe.', 'error')
        elif fila['id_estado_recurso'] not in (1, 2):
            flash('Solo se evalúan órganos Disponibles o Reservados.', 'error')
        elif fila['dias'] <= 0:
            flash('El órgano ya perdió su tiempo de viabilidad.', 'error')
        elif tipo is None or resultado is None:
            flash('Selecciona el tipo y el resultado de la evaluación.', 'error')
        else:
            cn.execute("""INSERT INTO evaluaciones_organo (id_recurso, id_personal, fecha_hora, id_tipo_evaluacion,
                                                           id_resultado_evaluacion, observaciones)
                          VALUES (%s, %s, now(), %s, %s, %s)""",
                       (id_recurso, session['id_personal'], tipo, resultado, obs))
            # resultado 4 = No apto -> No viable (3); cualquier otro -> Viable (1)
            viable = resultado != 4
            cn.execute("UPDATE organos SET id_viabilidad_organo = %s WHERE id_recurso = %s",
                       (1 if viable else 3, id_recurso))
            flash('Evaluación registrada, el órgano quedó %s.' % ('Viable' if viable else 'No viable'), 'ok')
    return redirect(url_for('organos'))


# ======================================================
# CRUD 3: SOLICITUDES (y matching)
# ======================================================
def solicitud_visible(id_hospital):
    return ve_toda_la_red() or id_hospital == session['id_institucion']


@app.route('/solicitudes')
@permiso_requerido('Registrar solicitudes', 'Consultar compatibilidad')
def solicitudes():
    filtros = {
        'todo': ve_toda_la_red(),
        'inst': session['id_institucion'],
        'estado': entero(request.args.get('estado'), 0),
        'urgencia': entero(request.args.get('urgencia'), 0),
        'recurso': entero(request.args.get('recurso'), 0),
        'q': request.args.get('q', '').strip(),
    }
    filtros['patron'] = '%' + filtros['q'] + '%'
    lista = consultar("""
        SELECT s.id_solicitud, sd.id_solicitud_detalle, i.nombre AS hospital,
               p.nombres || ' ' || p.apellidos AS receptor,
               COALESCE(cs.nombre || ' ' || ts.nombre, co.nombre) AS pide, sd.cantidad,
               u.nombre AS urgencia, es.nombre AS estado, s.fecha_hora_solicitud, s.fecha_limite,
               (SELECT count(*) FROM asignaciones a JOIN matching m ON m.id_matching = a.id_matching
                WHERE m.id_solicitud_detalle = sd.id_solicitud_detalle AND a.id_estado_asignacion IN (1, 2)) AS asignadas
        FROM solicitudes s
        JOIN solicitudes_detalle sd ON sd.id_solicitud = s.id_solicitud
        LEFT JOIN requisitos_sangre rs ON rs.id_solicitud_detalle = sd.id_solicitud_detalle
        LEFT JOIN cat_componentes_sangre cs ON cs.id_componente = rs.id_componente
        LEFT JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = rs.id_tipo_sanguineo
        LEFT JOIN requisitos_organo ro ON ro.id_solicitud_detalle = sd.id_solicitud_detalle
        LEFT JOIN cat_organos co ON co.id_tipo_organo = ro.id_tipo_organo
        JOIN instituciones i ON i.id_institucion = s.id_hospital
        JOIN receptores r ON r.id_receptor = s.id_receptor
        JOIN personas p ON p.id_persona = r.id_persona
        JOIN cat_urgencias u ON u.id_urgencia = s.id_urgencia
        JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud
        WHERE (%(todo)s OR s.id_hospital = %(inst)s)
          AND (%(estado)s = 0 OR s.id_estado_solicitud = %(estado)s)
          AND (%(urgencia)s = 0 OR s.id_urgencia = %(urgencia)s)
          AND (%(recurso)s = 0 OR sd.id_tipo_recurso = %(recurso)s)
          AND (%(q)s = '' OR p.nombres || ' ' || p.apellidos ILIKE %(patron)s OR s.id_solicitud::text = %(q)s)
        ORDER BY (s.id_estado_solicitud IN (1, 2)) DESC, u.peso DESC, s.fecha_hora_solicitud DESC
    """, filtros)
    return render_template('solicitudes.html', solicitudes=lista, f=filtros,
                           **catalogos('estados_solicitud', 'urgencias'))


@app.route('/solicitudes/nueva')
@permiso_requerido('Registrar solicitudes')
def solicitud_nueva():
    puede_sangre = session.get('tipo_institucion') == 'Hospital' and 'Transfusión' in session.get('servicios', [])
    puede_organo = 'Trasplante' in session.get('servicios', [])
    return render_template('solicitud_nueva.html', puede_sangre=puede_sangre, puede_organo=puede_organo,
                           **catalogos('receptores', 'componentes', 'urgencias', 'tipos_organo'))


@app.route('/solicitudes/nueva_sangre', methods=['POST'])
@permiso_requerido('Registrar solicitudes')
def solicitud_nueva_sangre():
    f = request.form
    datos = [entero(f.get('id_receptor')), entero(f.get('id_urgencia')), entero(f.get('id_componente')),
             entero(f.get('cantidad')), entero(f.get('horas_limite'))]
    motivo = f.get('motivo', '').strip()
    if None in datos or not motivo or len(motivo) > 255:
        flash('Todos los campos son obligatorios (motivo de máximo 255 caracteres).', 'error')
        return redirect(url_for('solicitud_nueva'))
    receptor, urgencia, componente, cantidad, horas = datos
    try:
        fila = llamar("CALL sp_registrar_solicitud_sangre(%s,%s,%s,%s,%s,%s,%s,NULL,NULL)",     # SP7
                      (receptor, session['id_personal'], urgencia, componente, cantidad, horas, motivo))
        flash('Solicitud %s registrada con %s candidatos compatibles.' % (fila['p_id_solicitud'], fila['p_candidatos']), 'ok')
        return redirect(url_for('solicitud_detalle', id_solicitud=fila['p_id_solicitud']))
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
        return redirect(url_for('solicitud_nueva'))


@app.route('/solicitudes/nueva_organo', methods=['POST'])
@permiso_requerido('Registrar solicitudes')
def solicitud_nueva_organo():
    f = request.form
    datos = [entero(f.get('id_receptor')), entero(f.get('id_urgencia')), entero(f.get('id_tipo_organo')),
             entero(f.get('horas_limite'))]
    tam_min, tam_max = numero(f.get('tamano_min')), numero(f.get('tamano_max'))
    motivo = f.get('motivo', '').strip()
    if None in datos or not motivo or 'error' in (tam_min, tam_max):
        flash('Revisa los datos: receptor, órgano, urgencia, horas y motivo son obligatorios.', 'error')
        return redirect(url_for('solicitud_nueva'))
    receptor, urgencia, organo, horas = datos
    try:
        fila = llamar("CALL sp_registrar_solicitud_organo(%s,%s,%s,%s,%s,%s,%s,%s,NULL,NULL)",   # SP14
                      (receptor, session['id_personal'], urgencia, organo, tam_min, tam_max, horas, motivo))
        flash('Solicitud %s registrada con %s órganos compatibles.' % (fila['p_id_solicitud'], fila['p_candidatos']), 'ok')
        return redirect(url_for('solicitud_detalle', id_solicitud=fila['p_id_solicitud']))
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
        return redirect(url_for('solicitud_nueva'))


def leer_solicitud(cn, id_solicitud):
    return cn.execute("""
        SELECT s.id_solicitud, s.id_hospital, s.id_urgencia, s.id_estado_solicitud, s.fecha_hora_solicitud,
               s.fecha_limite, s.motivo, s.observaciones, i.nombre AS hospital,
               p.nombres || ' ' || p.apellidos AS receptor, ts.nombre AS tipo_receptor,
               u.nombre AS urgencia, es.nombre AS estado, pp.nombres || ' ' || pp.apellidos AS solicitante
        FROM solicitudes s
        JOIN instituciones i ON i.id_institucion = s.id_hospital
        JOIN receptores r ON r.id_receptor = s.id_receptor
        JOIN personas p ON p.id_persona = r.id_persona
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
        JOIN cat_urgencias u ON u.id_urgencia = s.id_urgencia
        JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud
        JOIN personal pe ON pe.id_personal = s.id_personal
        JOIN personas pp ON pp.id_persona = pe.id_persona
        WHERE s.id_solicitud = %s""", (id_solicitud,)).fetchone()


@app.route('/solicitudes/<int:id_solicitud>')
@permiso_requerido('Registrar solicitudes', 'Consultar compatibilidad')
def solicitud_detalle(id_solicitud):
    with conectar() as cn:
        sol = leer_solicitud(cn, id_solicitud)
        if sol is None:
            abort(404)
        if not solicitud_visible(sol['id_hospital']):
            return render_template('error.html', titulo='Acceso denegado',
                                   mensaje='Solo puedes consultar las solicitudes de tu institución.'), 403
        lineas = cn.execute("""
            SELECT sd.id_solicitud_detalle, tr.nombre AS tipo_recurso, sd.cantidad,
                   COALESCE(cs.nombre || ' ' || ts.nombre,
                            co.nombre || COALESCE(' de ' || ro.tamano_minimo_cm || ' a ' || ro.tamano_maximo_cm || ' cm', '')) AS requisito,
                   (SELECT count(*) FROM asignaciones a JOIN matching m ON m.id_matching = a.id_matching
                    WHERE m.id_solicitud_detalle = sd.id_solicitud_detalle AND a.id_estado_asignacion IN (1, 2)) AS asignadas
            FROM solicitudes_detalle sd
            JOIN cat_tipos_recurso tr ON tr.id_tipo_recurso = sd.id_tipo_recurso
            LEFT JOIN requisitos_sangre rs ON rs.id_solicitud_detalle = sd.id_solicitud_detalle
            LEFT JOIN cat_componentes_sangre cs ON cs.id_componente = rs.id_componente
            LEFT JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = rs.id_tipo_sanguineo
            LEFT JOIN requisitos_organo ro ON ro.id_solicitud_detalle = sd.id_solicitud_detalle
            LEFT JOIN cat_organos co ON co.id_tipo_organo = ro.id_tipo_organo
            WHERE sd.id_solicitud = %s ORDER BY sd.id_solicitud_detalle""", (id_solicitud,)).fetchall()
        # vista_matching: candidatos evaluados y su asignación
        historial = cn.execute("""SELECT * FROM vista_matching WHERE id_solicitud = %s
                                  ORDER BY (estado IS NULL), fecha_hora_calculo DESC""", (id_solicitud,)).fetchall()
    return render_template('solicitud_detalle.html', sol=sol, lineas=lineas, historial=historial)


@app.route('/solicitudes/<int:id_solicitud>/editar', methods=['GET', 'POST'])
@permiso_requerido('Registrar solicitudes')
def solicitud_editar(id_solicitud):
    with conectar() as cn:
        sol = leer_solicitud(cn, id_solicitud)
    if sol is None:
        abort(404)
    if not solicitud_visible(sol['id_hospital']):
        return render_template('error.html', titulo='Acceso denegado',
                               mensaje='Solo puedes modificar las solicitudes de tu institución.'), 403
    if sol['id_estado_solicitud'] not in (1, 2):
        flash('Solo se modifican solicitudes En proceso o Aprobadas.', 'error')
        return redirect(url_for('solicitud_detalle', id_solicitud=id_solicitud))

    if request.method == 'POST':
        errores = []
        urgencia = entero(request.form.get('id_urgencia'))
        limite = request.form.get('fecha_limite', '').strip()
        motivo = request.form.get('motivo', '').strip()
        obs = request.form.get('observaciones', '').strip() or None
        if urgencia is None:
            errores.append('Selecciona la urgencia.')
        if not motivo or len(motivo) > 255:
            errores.append('El motivo es obligatorio (máximo 255 caracteres).')
        if not re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$', limite):
            errores.append('La fecha límite no es válida.')
        if not errores:
            with conectar() as cn:
                ok = cn.execute("SELECT %s::timestamptz > now() AS futura, %s::timestamptz >= %s AS valida",
                                (limite, limite, sol['fecha_hora_solicitud'])).fetchone()
                if not ok['futura'] or not ok['valida']:
                    errores.append('La fecha límite debe ser posterior a este momento.')
                else:
                    cn.execute("""UPDATE solicitudes SET id_urgencia = %s, fecha_limite = %s, motivo = %s,
                                  observaciones = %s WHERE id_solicitud = %s AND id_estado_solicitud IN (1, 2)""",
                               (urgencia, limite, motivo, obs, id_solicitud))
                    flash('Solicitud %s actualizada.' % id_solicitud, 'ok')
                    return redirect(url_for('solicitud_detalle', id_solicitud=id_solicitud))
        mostrar_errores(errores)
        valores = request.form
    else:
        valores = dict(sol)
        valores['fecha_limite'] = sol['fecha_limite'].strftime('%Y-%m-%dT%H:%M') if sol['fecha_limite'] else ''
    return render_template('solicitud_form.html', sol=sol, valores=valores, **catalogos('urgencias'))


@app.route('/solicitudes/<int:id_solicitud>/cancelar', methods=['POST'])
@permiso_requerido('Gestionar reservas')
def solicitud_cancelar(id_solicitud):
    motivo = request.form.get('motivo', '').strip()
    if not motivo:
        flash('Escribe el motivo de la cancelación.', 'error')
        return redirect(url_for('solicitud_detalle', id_solicitud=id_solicitud))
    try:
        # SP16: baja lógica (la solicitud queda Cancelada, no se borra)
        fila = llamar("CALL sp_cancelar_solicitud(%s,%s,%s,NULL)", (id_solicitud, session['id_personal'], motivo))
        flash('Solicitud %s cancelada; %s recurso(s) regresaron a Disponible.' % (id_solicitud, fila['p_liberados']), 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('solicitud_detalle', id_solicitud=id_solicitud))


@app.route('/matching/<int:id_detalle>')
@permiso_requerido('Consultar compatibilidad')
def matching(id_detalle):
    with conectar() as cn:
        linea = cn.execute("""SELECT sd.id_solicitud, s.id_hospital FROM solicitudes_detalle sd
                              JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
                              WHERE sd.id_solicitud_detalle = %s""", (id_detalle,)).fetchone()
    if linea is None:
        abort(404)
    if not solicitud_visible(linea['id_hospital']):
        return render_template('error.html', titulo='Acceso denegado',
                               mensaje='Solo puedes consultar las solicitudes de tu institución.'), 403
    try:
        fila = llamar("CALL sp_generar_matching(%s, NULL)", (id_detalle,))     # SP6, se recalcula al abrir
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
        return redirect(url_for('solicitud_detalle', id_solicitud=linea['id_solicitud']))

    candidatos = consultar("""
        SELECT m.id_matching, r.folio, ts.nombre AS tipo_sangre, i.nombre AS institucion,
               COALESCE(u.fecha_hora_caducidad, o.fecha_hora_caducidad) AS caducidad,
               fn_dias_restantes(r.id_recurso) AS dias, fn_puntaje_matching(m.id_matching) AS puntaje, m.explicacion
        FROM matching m
        JOIN recursos r ON r.id_recurso = m.id_recurso
        LEFT JOIN unidades_componentes_sanguineos u ON u.id_recurso = r.id_recurso
        LEFT JOIN organos o ON o.id_recurso = r.id_recurso
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
        JOIN instituciones i ON i.id_institucion = r.id_institucion
        WHERE m.id_solicitud_detalle = %s AND m.disponible = TRUE
          AND m.id_resultado_compatibilidad = 1 AND r.id_estado_recurso = 1
        ORDER BY 7 DESC, 5""", (id_detalle,))
    return render_template('matching.html', candidatos=candidatos, id_detalle=id_detalle,
                           id_solicitud=linea['id_solicitud'], total=fila['p_total'])


@app.route('/asignar', methods=['POST'])
@permiso_requerido('Aprobar asignaciones')
def asignar():
    id_matching = entero(request.form.get('id_matching'))
    id_detalle = entero(request.form.get('id_detalle'))
    motivo = request.form.get('motivo', '').strip()
    try:
        fila = llamar("CALL sp_asignar_recurso(%s,%s,%s,NULL)", (id_matching, session['id_personal'], motivo))  # SP8
        flash('Asignación %s creada, el recurso quedó Reservado.' % fila['p_id_asignacion'], 'ok')
        return redirect(url_for('asignaciones'))
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
        return redirect(url_for('matching', id_detalle=id_detalle))


# ======================================================
# ASIGNACIONES: TRASLADO, RECEPCIÓN, TRANSFUSIÓN Y TRASPLANTE
# ======================================================
@app.route('/asignaciones')
@permiso_requerido('Aprobar asignaciones', 'Gestionar traslados', 'Confirmar recepciones',
                   'Registrar utilización de recursos')
def asignaciones():
    todo = ve_toda_la_red() or tiene('Gestionar traslados')
    lista = consultar("""
        SELECT a.id_asignacion, s.id_solicitud, r.folio, ts.nombre AS tipo_sangre, io.nombre AS donde_esta,
               ih.nombre AS destino, er.nombre AS estado,
               (SELECT max(td.id_traslado) FROM traslado_detalle td
                JOIN traslados t ON t.id_traslado = td.id_traslado
                WHERE td.id_asignacion = a.id_asignacion AND t.id_estado_traslado = 2) AS id_traslado,
               p.nombres || ' ' || p.apellidos AS receptor, ih.id_institucion AS id_destino,
               r.id_tipo_recurso, COALESCE(cs.nombre, co.nombre) AS recurso
        FROM asignaciones a
        JOIN recursos r ON r.id_recurso = a.id_recurso
        LEFT JOIN unidades_componentes_sanguineos u ON u.id_recurso = r.id_recurso
        LEFT JOIN cat_componentes_sangre cs ON cs.id_componente = u.id_componente
        LEFT JOIN organos o ON o.id_recurso = r.id_recurso
        LEFT JOIN cat_organos co ON co.id_tipo_organo = o.id_tipo_organo
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
        JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
        JOIN instituciones io ON io.id_institucion = r.id_institucion
        JOIN matching m ON m.id_matching = a.id_matching
        JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
        JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
        JOIN instituciones ih ON ih.id_institucion = s.id_hospital
        JOIN receptores rc ON rc.id_receptor = s.id_receptor
        JOIN personas p ON p.id_persona = rc.id_persona
        WHERE a.id_estado_asignacion = 1 AND (%s OR s.id_hospital = %s)
        ORDER BY a.id_asignacion DESC""", (todo, session['id_institucion']))
    return render_template('asignaciones.html', asignaciones=lista,
                           **catalogos('medios_transporte', 'resultados_recepcion', 'resultados_transfusion'))


@app.route('/asignaciones/traslado', methods=['POST'])
@permiso_requerido('Gestionar traslados')
def programar_traslado():
    datos = (entero(request.form.get('id_asignacion')), session['id_personal'],
             entero(request.form.get('id_medio')), entero(request.form.get('minutos')))
    try:
        fila = llamar("CALL sp_programar_traslado(%s,%s,%s,%s,NULL)", datos)       # SP9
        flash('Traslado %s en tránsito.' % fila['p_id_traslado'], 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('asignaciones'))


@app.route('/asignaciones/recepcion', methods=['POST'])
@permiso_requerido('Confirmar recepciones')
def registrar_recepcion():
    id_traslado = entero(request.form.get('id_traslado'))
    resultado = entero(request.form.get('id_resultado'))
    obs = request.form.get('observaciones', '').strip() or None
    try:
        fila = llamar("CALL sp_registrar_recepcion(%s,%s,%s,%s,NULL)",            # SP10
                      (id_traslado, session['id_personal'], resultado, obs))
        flash('Traslado %s: %s.' % (id_traslado, fila['p_resultado']), 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('asignaciones'))


@app.route('/asignaciones/transfusion', methods=['POST'])
@permiso_requerido('Registrar utilización de recursos')
def registrar_transfusion():
    id_asignacion = entero(request.form.get('id_asignacion'))
    resultado = entero(request.form.get('id_resultado'))
    try:
        fila = llamar("CALL sp_registrar_transfusion(%s,%s,%s,NULL)",              # SP11
                      (id_asignacion, session['id_personal'], resultado))
        flash('Transfusión %s registrada.' % fila['p_id_transfusion'], 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('asignaciones'))


@app.route('/asignaciones/trasplante', methods=['POST'])
@permiso_requerido('Registrar utilización de recursos')
def registrar_trasplante():
    id_asignacion = entero(request.form.get('id_asignacion'))
    try:
        fila = llamar("CALL sp_registrar_trasplante(%s,%s,NULL)", (id_asignacion, session['id_personal']))  # SP15
        flash('Trasplante registrado (operación %s).' % fila['p_id_operacion'], 'ok')
    except ERRORES_SP as e:
        flash(mensaje_error(e), 'error')
    return redirect(url_for('asignaciones'))


# ======================================================
# TRASLADOS (vista_traslados)
# ======================================================
@app.route('/traslados')
@permiso_requerido('Gestionar traslados', 'Confirmar recepciones')
def traslados():
    estado = request.args.get('estado', '')
    lista = consultar("""
        SELECT * FROM vista_traslados
        WHERE (%(todo)s OR %(inst)s IN (id_institucion_origen, id_institucion_destino))
          AND (%(estado)s = '' OR estado = %(estado)s)
        ORDER BY (estado = 'En tránsito') DESC, fecha_salida DESC""",
                      {'todo': ve_toda_la_red() or tiene('Gestionar traslados'),
                       'inst': session['id_institucion'], 'estado': estado})
    return render_template('traslados.html', traslados=lista, estado=estado, **catalogos('estados_traslado'))


# ======================================================
# REPORTES (vista + CTE + funciones de ventana)
# ======================================================
@app.route('/reportes')
@permiso_requerido('Consultar reportes regionales')
def reportes():
    with conectar() as cn:
        activas = cn.execute("SELECT * FROM vista_hospitales_solicitudes_activas").fetchall()
        # consulta 11 (CTE): aprovechamiento y desperdicio por banco
        aprovechamiento = cn.execute("""
            WITH unidades AS (
                SELECT r.id_institucion, r.id_recurso, er.nombre AS estado
                FROM recursos r
                JOIN unidades_componentes_sanguineos u ON u.id_recurso = r.id_recurso
                JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
            ),
            resumen AS (
                SELECT id_institucion, count(*) AS producidas,
                       count(*) FILTER (WHERE estado = 'Utilizado') AS utilizadas,
                       count(*) FILTER (WHERE estado = 'Descartado') AS descartadas,
                       count(*) FILTER (WHERE estado IN ('Disponible', 'Reservado', 'En traslado')) AS en_inventario
                FROM unidades GROUP BY id_institucion
            )
            SELECT i.nombre AS institucion, r.producidas, r.utilizadas, r.descartadas, r.en_inventario,
                   round(100.0 * r.utilizadas / r.producidas, 1) AS pct_aprovechado,
                   round(100.0 * r.descartadas / r.producidas, 1) AS pct_desperdicio
            FROM resumen r JOIN instituciones i ON i.id_institucion = r.id_institucion
            ORDER BY pct_aprovechado DESC""").fetchall()
        # consulta 12 (ventana): ranking de hospitales por consumo
        ranking = cn.execute("""
            SELECT h.nombre AS hospital, count(*) AS unidades,
                   RANK() OVER (ORDER BY count(*) DESC) AS ranking,
                   sum(count(*)) OVER (ORDER BY count(*) DESC, h.nombre) AS acumulado,
                   round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
            FROM transfusiones t JOIN instituciones h ON h.id_institucion = t.id_institucion
            GROUP BY h.nombre ORDER BY ranking""").fetchall()
    return render_template('reportes.html', activas=activas, aprovechamiento=aprovechamiento, ranking=ranking)


# ======================================================
# CRUD 2: PERSONAL (médicos, laboratorio, logística...)
# ======================================================
@app.route('/personal')
@permiso_requerido('Gestionar usuarios y roles')
def personal():
    filtros = {
        'q': request.args.get('q', '').strip(),
        'institucion': entero(request.args.get('institucion'), 0),
        'cargo': entero(request.args.get('cargo'), 0),
        'estado': entero(request.args.get('estado'), 0),
    }
    filtros['patron'] = '%' + filtros['q'] + '%'
    # LEFT JOIN: aparece todo el personal, tenga o no cuenta de usuario (consulta 2)
    lista = consultar("""
        SELECT pe.id_personal, p.nombres || ' ' || p.apellidos AS nombre, c.nombre AS cargo,
               i.nombre AS institucion, pe.cedula_profesional, ep.nombre AS estado,
               u.usuario_login, eu.nombre AS estado_usuario
        FROM personal pe
        JOIN personas p ON p.id_persona = pe.id_persona
        JOIN cat_cargos c ON c.id_cargo = pe.id_cargo
        JOIN instituciones i ON i.id_institucion = pe.id_institucion
        JOIN cat_estados_personal ep ON ep.id_estado_personal = pe.id_estado_personal
        LEFT JOIN usuarios u ON u.id_personal = pe.id_personal
        LEFT JOIN cat_estados_usuario eu ON eu.id_estado_usuario = u.id_estado_usuario
        WHERE (%(q)s = '' OR p.nombres || ' ' || p.apellidos ILIKE %(patron)s OR pe.cedula_profesional ILIKE %(patron)s)
          AND (%(institucion)s = 0 OR pe.id_institucion = %(institucion)s)
          AND (%(cargo)s = 0 OR pe.id_cargo = %(cargo)s)
          AND (%(estado)s = 0 OR pe.id_estado_personal = %(estado)s)
        ORDER BY p.nombres, p.apellidos""", filtros)
    return render_template('personal.html', personal=lista, f=filtros,
                           **catalogos('instituciones', 'cargos', 'estados_personal'))


def leer_datos_personal(errores):
    d = leer_persona(errores, 18, 100)
    d['id_institucion'] = entero(request.form.get('id_institucion'))
    d['id_cargo'] = entero(request.form.get('id_cargo'))
    d['cedula'] = request.form.get('cedula', '').strip().upper() or None
    if d['id_institucion'] is None or d['id_cargo'] is None:
        errores.append('Selecciona la institución y el cargo.')
    if d['cedula'] and len(d['cedula']) > 20:
        errores.append('La cédula profesional tiene máximo 20 caracteres.')
    return d


@app.route('/personal/nuevo', methods=['GET', 'POST'])
@permiso_requerido('Gestionar usuarios y roles')
def personal_nuevo():
    if request.method == 'POST':
        errores = []
        d = leer_datos_personal(errores)
        if not errores:
            try:
                with conectar() as cn:
                    activa = cn.execute("SELECT id_estado_institucion = 1 AS activa FROM instituciones WHERE id_institucion = %s",
                                        (d['id_institucion'],)).fetchone()
                    if not activa or not activa['activa']:
                        errores.append('La institución no existe o no está Activa.')
                    else:
                        id_persona = cn.execute("""INSERT INTO personas (id_sexo, nombres, apellidos, fecha_nacimiento, correo)
                                                   VALUES (%s, %s, %s, %s, %s) RETURNING id_persona""",
                                                (d['id_sexo'], d['nombres'], d['apellidos'],
                                                 d['fecha_nacimiento'], d['correo'])).fetchone()['id_persona']
                        if d['telefono']:
                            cn.execute("INSERT INTO telefonos (id_persona, telefono, id_tipo_telefono) VALUES (%s, %s, 3)",
                                       (id_persona, d['telefono']))
                        id_personal = cn.execute("""INSERT INTO personal (id_persona, id_institucion, id_cargo,
                                                                          cedula_profesional, id_estado_personal)
                                                    VALUES (%s, %s, %s, %s, 1) RETURNING id_personal""",
                                                 (id_persona, d['id_institucion'], d['id_cargo'],
                                                  d['cedula'])).fetchone()['id_personal']
                if not errores:
                    flash('Personal registrado con id %s. Ya le puedes crear su usuario.' % id_personal, 'ok')
                    return redirect(url_for('personal_detalle', id_personal=id_personal))
            except (psycopg.errors.UniqueViolation, psycopg.errors.CheckViolation,
                    psycopg.errors.ForeignKeyViolation) as e:
                errores.append(mensaje_restriccion(e))
        mostrar_errores(errores)
    return render_template('personal_form.html', persona=None, valores=request.form,
                           **catalogos('sexos', 'instituciones_activas', 'cargos', 'estados_personal'))


@app.route('/personal/<int:id_personal>')
@permiso_requerido('Gestionar usuarios y roles')
def personal_detalle(id_personal):
    with conectar() as cn:
        persona = cn.execute("""
            SELECT pe.id_personal, pe.id_persona, p.nombres, p.apellidos, p.fecha_nacimiento, p.correo,
                   fn_calcular_edad(p.fecha_nacimiento) AS edad, sx.nombre AS sexo, c.nombre AS cargo,
                   i.nombre AS institucion, pe.cedula_profesional, ep.nombre AS estado, pe.id_estado_personal,
                   u.id_usuario, u.usuario_login, eu.nombre AS estado_usuario, u.ultimo_acceso,
                   (SELECT string_agg(r.nombre, ', ' ORDER BY r.nombre) FROM usuario_rol ur
                    JOIN cat_roles r ON r.id_rol = ur.id_rol WHERE ur.id_usuario = u.id_usuario) AS roles,
                   (SELECT count(*) FROM donaciones x WHERE x.id_personal = pe.id_personal) AS donaciones,
                   (SELECT count(*) FROM solicitudes x WHERE x.id_personal = pe.id_personal) AS solicitudes,
                   (SELECT count(*) FROM transfusiones x WHERE x.id_personal = pe.id_personal) AS transfusiones,
                   (SELECT count(*) FROM traslados x WHERE x.id_personal = pe.id_personal) AS traslados
            FROM personal pe
            JOIN personas p ON p.id_persona = pe.id_persona
            JOIN cat_sexo sx ON sx.id_sexo = p.id_sexo
            JOIN cat_cargos c ON c.id_cargo = pe.id_cargo
            JOIN instituciones i ON i.id_institucion = pe.id_institucion
            JOIN cat_estados_personal ep ON ep.id_estado_personal = pe.id_estado_personal
            LEFT JOIN usuarios u ON u.id_personal = pe.id_personal
            LEFT JOIN cat_estados_usuario eu ON eu.id_estado_usuario = u.id_estado_usuario
            WHERE pe.id_personal = %s""", (id_personal,)).fetchone()
        if persona is None:
            abort(404)
        telefonos = cn.execute("""SELECT t.telefono, tt.nombre AS tipo FROM telefonos t
                                  JOIN cat_tipos_telefono tt ON tt.id_tipo_telefono = t.id_tipo_telefono
                                  WHERE t.id_persona = %s ORDER BY t.id_telefono""",
                               (persona['id_persona'],)).fetchall()
    return render_template('personal_detalle.html', persona=persona, telefonos=telefonos, **catalogos('roles'))


@app.route('/personal/<int:id_personal>/editar', methods=['GET', 'POST'])
@permiso_requerido('Gestionar usuarios y roles')
def personal_editar(id_personal):
    actual = consultar_uno("""
        SELECT pe.id_personal, pe.id_persona, pe.id_institucion, pe.id_cargo, pe.cedula_profesional AS cedula,
               pe.id_estado_personal, p.nombres, p.apellidos, p.fecha_nacimiento, p.id_sexo, p.correo,
               (SELECT t.telefono FROM telefonos t WHERE t.id_persona = pe.id_persona ORDER BY t.id_telefono LIMIT 1) AS telefono
        FROM personal pe JOIN personas p ON p.id_persona = pe.id_persona
        WHERE pe.id_personal = %s""", (id_personal,))
    if actual is None:
        abort(404)

    if request.method == 'POST':
        errores = []
        d = leer_datos_personal(errores)
        estado = entero(request.form.get('id_estado_personal'))
        if estado is None:
            errores.append('Selecciona el estado.')
        if id_personal == session['id_personal'] and estado != 1:
            errores.append('No puedes desactivar tu propio registro.')
        if not errores:
            try:
                with conectar() as cn:
                    if d['id_institucion'] != actual['id_institucion']:
                        activa = cn.execute("SELECT id_estado_institucion = 1 AS activa FROM instituciones WHERE id_institucion = %s",
                                            (d['id_institucion'],)).fetchone()
                        if not activa or not activa['activa']:
                            raise ValueError('La institución nueva no existe o no está Activa.')
                    cn.execute("""UPDATE personas SET nombres = %s, apellidos = %s, fecha_nacimiento = %s,
                                  id_sexo = %s, correo = %s WHERE id_persona = %s""",
                               (d['nombres'], d['apellidos'], d['fecha_nacimiento'], d['id_sexo'],
                                d['correo'], actual['id_persona']))
                    actualizar_telefono(cn, actual['id_persona'], actual['telefono'], d['telefono'], 3)
                    cn.execute("""UPDATE personal SET id_institucion = %s, id_cargo = %s, cedula_profesional = %s,
                                  id_estado_personal = %s WHERE id_personal = %s""",
                               (d['id_institucion'], d['id_cargo'], d['cedula'], estado, id_personal))
                    if estado != 1:
                        # sin personal activo no hay acceso: su usuario también se desactiva
                        cn.execute("UPDATE usuarios SET id_estado_usuario = 2 WHERE id_personal = %s", (id_personal,))
                flash('Datos del personal actualizados.', 'ok')
                return redirect(url_for('personal_detalle', id_personal=id_personal))
            except ValueError as e:
                errores.append(str(e))
            except (psycopg.errors.UniqueViolation, psycopg.errors.CheckViolation,
                    psycopg.errors.ForeignKeyViolation) as e:
                errores.append(mensaje_restriccion(e))
        mostrar_errores(errores)
        valores = request.form
    else:
        valores = actual
    return render_template('personal_form.html', persona=actual, valores=valores,
                           **catalogos('sexos', 'instituciones_activas', 'cargos', 'estados_personal'))


@app.route('/personal/<int:id_personal>/eliminar', methods=['POST'])
@permiso_requerido('Gestionar usuarios y roles')
def personal_eliminar(id_personal):
    if id_personal == session['id_personal']:
        flash('No puedes eliminar tu propio registro.', 'error')
        return redirect(url_for('personal_detalle', id_personal=id_personal))
    with conectar() as cn:
        fila = cn.execute("SELECT id_persona FROM personal WHERE id_personal = %s", (id_personal,)).fetchone()
        if fila is None:
            abort(404)
        try:
            # solo se borra si no participó en ningún registro (donaciones, solicitudes, traslados...)
            with cn.transaction():
                cn.execute("""DELETE FROM usuario_rol WHERE id_usuario IN
                              (SELECT id_usuario FROM usuarios WHERE id_personal = %s)""", (id_personal,))
                cn.execute("DELETE FROM usuarios WHERE id_personal = %s", (id_personal,))
                cn.execute("DELETE FROM personal WHERE id_personal = %s", (id_personal,))
            eliminado = True
        except psycopg.errors.ForeignKeyViolation:
            eliminado = False

        if eliminado:
            try:
                with cn.transaction():
                    cn.execute("DELETE FROM telefonos WHERE id_persona = %s", (fila['id_persona'],))
                    cn.execute("DELETE FROM personas WHERE id_persona = %s", (fila['id_persona'],))
            except psycopg.errors.ForeignKeyViolation:
                pass
            flash('Personal %s eliminado (no tenía registros asociados).' % id_personal, 'ok')
            return redirect(url_for('personal'))

        cn.execute("UPDATE personal SET id_estado_personal = 2 WHERE id_personal = %s", (id_personal,))
        cn.execute("UPDATE usuarios SET id_estado_usuario = 2 WHERE id_personal = %s", (id_personal,))
        flash('El personal tiene registros en el historial: se dio de baja lógica '
              '(personal y usuario Inactivos).', 'ok')
    return redirect(url_for('personal_detalle', id_personal=id_personal))


@app.route('/personal/<int:id_personal>/usuario', methods=['POST'])
@permiso_requerido('Gestionar usuarios y roles')
def personal_crear_usuario(id_personal):
    login_nuevo = request.form.get('usuario_login', '').strip().lower()
    password = request.form.get('password', '')
    confirmar = request.form.get('confirmar', '')
    rol = entero(request.form.get('id_rol'))
    errores = []
    if not RE_LOGIN.match(login_nuevo):
        errores.append('El usuario debe tener de 4 a 50 caracteres: letras minúsculas, números, punto o guion bajo.')
    if len(password) < 8 or not re.search(r'[A-Za-z]', password) or not re.search(r'\d', password):
        errores.append('La contraseña debe tener al menos 8 caracteres, con letras y números.')
    if password != confirmar:
        errores.append('Las contraseñas no coinciden.')
    if rol is None:
        errores.append('Selecciona el rol.')
    if not errores:
        try:
            with conectar() as cn:
                pe = cn.execute("""SELECT pe.id_estado_personal,
                                          EXISTS (SELECT 1 FROM usuarios u WHERE u.id_personal = pe.id_personal) AS tiene_usuario
                                   FROM personal pe WHERE pe.id_personal = %s""", (id_personal,)).fetchone()
                if pe is None:
                    abort(404)
                if pe['id_estado_personal'] != 1:
                    errores.append('Solo el personal Activo puede tener usuario.')
                elif pe['tiene_usuario']:
                    errores.append('Esta persona ya tiene usuario.')
                else:
                    # la contraseña se guarda como hash bcrypt (pgcrypto), nunca en texto
                    id_usuario = cn.execute("""INSERT INTO usuarios (id_personal, usuario_login, password_hash, id_estado_usuario)
                                               VALUES (%s, %s, crypt(%s, gen_salt('bf', 10)), 1) RETURNING id_usuario""",
                                            (id_personal, login_nuevo, password)).fetchone()['id_usuario']
                    cn.execute("INSERT INTO usuario_rol (id_usuario, id_rol) VALUES (%s, %s)", (id_usuario, rol))
                    flash('Usuario %s creado.' % login_nuevo, 'ok')
        except psycopg.errors.UniqueViolation as e:
            errores.append(mensaje_restriccion(e))
    mostrar_errores(errores)
    return redirect(url_for('personal_detalle', id_personal=id_personal))


if __name__ == '__main__':
    # para desarrollo; en el servidor se usa gunicorn (ver README)
    app.run(host=os.environ.get('FLASK_HOST', '127.0.0.1'), port=int(os.environ.get('FLASK_PORT', '5000')),
            debug=os.environ.get('FLASK_DEBUG') == '1')
