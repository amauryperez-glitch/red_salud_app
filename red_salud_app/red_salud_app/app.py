from flask import Flask, request, render_template, redirect, url_for, session
import psycopg
import os

app = Flask(__name__)

# clave para que Flask pueda guardar la sesion (usuario que entro)
app.secret_key = os.environ.get('SECRET_KEY') or os.urandom(24)

# configuracion base de datos (la contraseña se toma de la variable de entorno DB_PASSWORD)
DB_HOST = os.environ.get('DB_HOST', 'localhost')
DB_USER = os.environ.get('DB_USER', 'app_banco')
DB_PASSWORD = os.environ.get('DB_PASSWORD', '')
DB_NAME = os.environ.get('DB_NAME', 'banco_sangre_organos')

print("Aplicacion conectada a la base de datos")


def conectar():
    # Crear conexion con la base de datos
    return psycopg.connect(
        host=DB_HOST,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )


def catalogo(cur, nombre):
    # Trae (id, nombre) de un catalogo para llenar un <select>
    cur.execute("CALL sp_obtener_catalogo(%s, NULL)", (nombre,))
    cur.execute("FETCH ALL FROM cursor_" + nombre)
    return cur.fetchall()


def mensaje_error(e):
    # El procedimiento manda el mensaje del RAISE EXCEPTION, nos quedamos con la primera linea
    return str(e).split('\n')[0]


def tiene(permiso):
    # ¿El usuario que entro tiene este permiso? (vienen de rol_permiso)
    return permiso in session.get('permisos', [])


def ve_todo():
    # el coordinador regional ve toda la red; los demas solo su institucion
    return tiene('Consultar reportes regionales')


def sin_permiso():
    # pagina de error cuando el rol no puede entrar
    return render_template('error.html', titulo='Acceso denegado',
                           mensaje='Tu rol (' + session['roles'] + ') no tiene permiso para esta página'), 403


# las plantillas pueden preguntar tiene('permiso')
app.jinja_env.globals['tiene'] = tiene


# formato de fechas en las plantillas
@app.template_filter('fecha')
def fecha(valor):
    if valor:
        return valor.strftime('%d/%m/%Y')
    return ''


@app.template_filter('fechahora')
def fechahora(valor):
    if valor:
        return valor.strftime('%d/%m/%Y %H:%M')
    return ''


# si PostgreSQL no responde se muestra una pagina de error
@app.errorhandler(psycopg.OperationalError)
def sin_conexion(e):
    return render_template('error.html', titulo='Sin conexión con la base de datos',
                           mensaje='No fue posible conectarse a PostgreSQL. Intenta de nuevo en unos minutos.'), 503


@app.errorhandler(404)
def no_encontrado(e):
    return render_template('error.html', titulo='No encontrado',
                           mensaje='La página o el registro que buscas no existe.'), 404


# ======================================================
# LOGIN
# ======================================================
@app.route("/")
def principal():
    if 'id_usuario' in session:
        return redirect(url_for('inicio'))
    return render_template('login.html')


@app.route('/entrar', methods=['POST'])
def entrar():
    usuario = request.form['usuario']
    password = request.form['password']

    conexion = conectar()
    cur = conexion.cursor()
    # El procedimiento revisa el usuario y el hash de la contraseña
    cur.execute("CALL sp_validar_login(%s, %s, NULL)", (usuario, password))
    cur.execute("FETCH ALL FROM cursor_login")
    Usuario = cur.fetchone()
    conexion.commit()   # guarda ultimo_acceso
    cur.close()
    conexion.close()

    if Usuario is None:
        return redirect(url_for('principal', error='Usuario o contraseña incorrectos, o la cuenta no está activa'))

    session.clear()
    session['id_usuario'] = Usuario[0]
    session['id_personal'] = Usuario[1]
    session['nombre'] = Usuario[2]
    session['cargo'] = Usuario[3]
    session['id_institucion'] = Usuario[4]
    session['institucion'] = Usuario[5]
    session['roles'] = Usuario[6] or ''
    session['permisos'] = []
    if Usuario[7]:
        session['permisos'] = Usuario[7].split(';')
    session['tipo_institucion'] = Usuario[8]
    session['servicios'] = []
    if Usuario[9]:
        session['servicios'] = Usuario[9].split(';')
    return redirect(url_for('inicio'))


@app.route('/salir')
def salir():
    session.clear()
    return redirect(url_for('principal', ok='Sesión cerrada'))


@app.route('/inicio')
def inicio():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_inicio(%s, %s, NULL, NULL, NULL)", (session['id_institucion'], ve_todo()))
    cur.execute("FETCH ALL FROM cursor_proximos")
    Proximos = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_minimos")
    Minimos = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_activas")
    Activas = cur.fetchall()
    cur.close()
    conexion.close()
    return render_template('inicio.html', Proximos=Proximos, Minimos=Minimos, Activas=Activas)


# ======================================================
# CRUD 1: DONANTES
# ======================================================
@app.route('/donantes')
def donantes():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar donaciones'):
        return sin_permiso()

    buscar = request.args.get('q') or None
    tipo = request.args.get('tipo') or None
    estado = request.args.get('estado') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_donantes(%s, %s, %s, NULL)", (buscar, tipo, estado))
    cur.execute("FETCH ALL FROM cursor_donantes")
    Donantes = cur.fetchall()
    Tipos = catalogo(cur, 'tipos_sangre')
    Estados = catalogo(cur, 'estados_donante')
    cur.close()
    conexion.close()
    return render_template('donantes.html', Donantes=Donantes, Tipos=Tipos, Estados=Estados)


@app.route('/insertardonante')
def insertardonante():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar donaciones'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    Tipos = catalogo(cur, 'tipos_sangre')
    Sexos = catalogo(cur, 'sexos')
    cur.close()
    conexion.close()
    return render_template('donante_form.html', Donante=None, Tipos=Tipos, Sexos=Sexos, Estados=[])


@app.route('/registradonante', methods=['POST'])
def registradonante():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    nombres = request.form['nombres']
    apellidos = request.form['apellidos']
    fecha_n = request.form['fecha_nacimiento'] or None
    sexo = request.form['id_sexo'] or None
    correo = request.form['correo'] or None
    tel = request.form['telefono'] or None
    tipo = request.form['id_tipo_sanguineo'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_donante(%s,%s,%s,%s,%s,%s,%s,%s,NULL)",
                    (nombres, apellidos, fecha_n, sexo, correo, tel, tipo, session['id_personal']))
        id_donante = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('insertardonante', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('donante', id_donante=id_donante, ok='Donante registrado con id ' + str(id_donante)))


@app.route('/donante/<int:id_donante>')
def donante(id_donante):
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar donaciones'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_donante(%s, NULL, NULL, NULL, NULL)", (id_donante,))
    cur.execute("FETCH ALL FROM cursor_donante")
    Donante = cur.fetchone()
    cur.execute("FETCH ALL FROM cursor_telefonos")
    Telefonos = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_historial")
    Historial = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_organos")
    Organos = cur.fetchall()
    cur.close()
    conexion.close()

    if Donante is None:
        return no_encontrado(None)
    return render_template('donante_detalle.html', Donante=Donante, Telefonos=Telefonos,
                           Historial=Historial, Organos=Organos)


# Formulario de actualizar
@app.route('/editardonante/<int:id_donante>', methods=['GET'])
def editardonante(id_donante):
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar donaciones'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_donante(%s, NULL, NULL, NULL, NULL)", (id_donante,))
    cur.execute("FETCH ALL FROM cursor_donante")
    Donante = cur.fetchone()
    Tipos = catalogo(cur, 'tipos_sangre')
    Sexos = catalogo(cur, 'sexos')
    Estados = catalogo(cur, 'estados_donante')
    cur.close()
    conexion.close()

    if Donante is None:
        return no_encontrado(None)
    return render_template('donante_form.html', Donante=Donante, Tipos=Tipos, Sexos=Sexos, Estados=Estados)


@app.route('/actualizardonante', methods=['POST'])
def actualizardonante():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_donante = request.form['id_donante']
    nombres = request.form['nombres']
    apellidos = request.form['apellidos']
    fecha_n = request.form['fecha_nacimiento'] or None
    sexo = request.form['id_sexo'] or None
    correo = request.form['correo'] or None
    tel = request.form['telefono'] or None
    tipo = request.form['id_tipo_sanguineo'] or None
    estado = request.form['id_estado_donante'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_actualizar_donante(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                    (id_donante, nombres, apellidos, fecha_n, sexo, correo, tel, tipo, estado, session['id_personal']))
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('editardonante', id_donante=id_donante, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('donante', id_donante=id_donante, ok='Datos del donante actualizados'))


@app.route('/borrardonante', methods=['POST'])
def borrardonante():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_donante = request.form['id_donante']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        # si tiene historial no se borra: se da de baja (Inactivo)
        cur.execute("CALL sp_eliminar_donante(%s,%s,NULL)", (id_donante, session['id_personal']))
        resultado = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('donante', id_donante=id_donante, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    if resultado == 'Eliminado':
        return redirect(url_for('donantes', ok='Donante ' + id_donante + ' eliminado (no tenía historial)'))
    return redirect(url_for('donante', id_donante=id_donante,
                            ok='El donante tiene historial, no se borra: ' + resultado + ' (Inactivo)'))


# ======================================================
# RECEPTORES
# ======================================================
@app.route('/receptores')
def receptores():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar solicitudes'):
        return sin_permiso()

    buscar = request.args.get('q') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_receptores(%s, NULL)", (buscar,))
    cur.execute("FETCH ALL FROM cursor_receptores")
    Receptores = cur.fetchall()
    Tipos = catalogo(cur, 'tipos_sangre')
    Sexos = catalogo(cur, 'sexos')
    cur.close()
    conexion.close()
    return render_template('receptores.html', Receptores=Receptores, Tipos=Tipos, Sexos=Sexos)


@app.route('/registrareceptor', methods=['POST'])
def registrareceptor():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    nombres = request.form['nombres']
    apellidos = request.form['apellidos']
    fecha_n = request.form['fecha_nacimiento'] or None
    sexo = request.form['id_sexo'] or None
    correo = request.form['correo'] or None
    tel = request.form['telefono'] or None
    tipo = request.form['id_tipo_sanguineo'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_receptor(%s,%s,%s,%s,%s,%s,%s,%s,NULL)",
                    (nombres, apellidos, fecha_n, sexo, correo, tel, tipo, session['id_personal']))
        id_receptor = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('receptores', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('receptores', ok='Receptor registrado con id ' + str(id_receptor)))


# ======================================================
# DONACIONES Y LABORATORIO
# ======================================================
@app.route('/donaciones')
def donaciones():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not (tiene('Registrar donaciones') or tiene('Validar resultados de laboratorio') or tiene('Registrar estudios')):
        return sin_permiso()

    estado = request.args.get('estado') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_donaciones(%s, NULL)", (estado,))
    cur.execute("FETCH ALL FROM cursor_donaciones")
    Donaciones = cur.fetchall()
    Estados = catalogo(cur, 'estados_donacion')
    Donantes = catalogo(cur, 'donantes_activos')
    cur.close()
    conexion.close()
    return render_template('donaciones.html', Donaciones=Donaciones, Estados=Estados, Donantes=Donantes)


@app.route('/registradonacion', methods=['POST'])
def registradonacion():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_donante = request.form['id_donante'] or None
    volumen = request.form['volumen_ml'] or None
    folio = request.form['folio_consentimiento']
    obs = request.form['observaciones'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_donacion(%s,%s,%s,%s,%s,NULL)",
                    (id_donante, session['id_personal'], volumen, folio, obs))
        id_donacion = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('donaciones', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('donaciones', ok='Donación ' + str(id_donacion) + ' registrada, queda Pendiente de laboratorio'))


@app.route('/resultadolaboratorio', methods=['POST'])
def resultadolaboratorio():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_donacion = request.form['id_donacion']
    vih = request.form['vih']
    hep_b = request.form['hepatitis_b']
    hep_c = request.form['hepatitis_c']
    sifilis = request.form['sifilis']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_resultado_laboratorio(%s,%s,%s,%s,%s,%s,NULL)",
                    (id_donacion, session['id_personal'], vih, hep_b, hep_c, sifilis))
        resultado = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('donaciones', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('donaciones', ok='Donación ' + id_donacion + ': ' + resultado))


@app.route('/fraccionar', methods=['POST'])
def fraccionar():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_donacion = request.form['id_donacion']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_fraccionar_donacion(%s,%s,NULL)", (id_donacion, session['id_personal']))
        total = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('donaciones', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('donaciones', ok='Se crearon ' + str(total) + ' unidades en el inventario'))


# ======================================================
# INVENTARIO
# ======================================================
@app.route('/inventario')
def inventario():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not (tiene('Consultar inventario y alertas') or tiene('Registrar descartes')):
        return sin_permiso()

    banco = request.args.get('banco') or None
    tipo = request.args.get('tipo') or None
    componente = request.args.get('componente') or None
    estado = request.args.get('estado') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_inventario(%s, %s, %s, %s, NULL, NULL)", (banco, tipo, componente, estado))
    cur.execute("FETCH ALL FROM cursor_sangre")
    Sangre = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_organos_inv")
    Organos = cur.fetchall()
    Instituciones = catalogo(cur, 'instituciones')
    Tipos = catalogo(cur, 'tipos_sangre')
    Componentes = catalogo(cur, 'componentes')
    Estados = catalogo(cur, 'estados_recurso')
    Causas = catalogo(cur, 'causas_descarte')
    cur.close()
    conexion.close()
    return render_template('inventario.html', Sangre=Sangre, Organos=Organos, Instituciones=Instituciones,
                           Tipos=Tipos, Componentes=Componentes, Estados=Estados, Causas=Causas)


@app.route('/descartar', methods=['POST'])
def descartar():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_recurso = request.form['id_recurso']
    causa = request.form['id_causa']
    motivo = request.form['motivo']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_descartar_recurso(%s,%s,%s,%s)", (id_recurso, causa, session['id_personal'], motivo))
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('inventario', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('inventario', ok='Recurso ' + id_recurso + ' descartado'))


# ======================================================
# ORGANOS
# ======================================================
@app.route('/organos')
def organos():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar evaluaciones de órganos'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_organos(NULL)")
    cur.execute("FETCH ALL FROM cursor_organos")
    Organos = cur.fetchall()
    TiposEval = catalogo(cur, 'tipos_evaluacion')
    ResEval = catalogo(cur, 'resultados_evaluacion')
    TiposOrgano = catalogo(cur, 'tipos_organo')
    Lados = catalogo(cur, 'lados')
    Donantes = catalogo(cur, 'donantes_organo')
    cur.close()
    conexion.close()
    return render_template('organos.html', Organos=Organos, TiposEval=TiposEval, ResEval=ResEval,
                           TiposOrgano=TiposOrgano, Lados=Lados, Donantes=Donantes)


@app.route('/registraorgano', methods=['POST'])
def registraorgano():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_donante = request.form['id_donante'] or None
    tipo = request.form['id_tipo_organo'] or None
    lado = request.form['id_lado'] or None
    peso = request.form['peso_gramos'] or None
    tamano = request.form['tamano_cm'] or None
    horas = request.form['horas_viabilidad'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_organo(%s,%s,%s,%s,%s,%s,%s,NULL)",
                    (session['id_personal'], id_donante, tipo, lado, peso, tamano, horas))
        id_recurso = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('organos', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('organos', ok='Órgano registrado (recurso ' + str(id_recurso) + '), queda En evaluación'))


@app.route('/evaluarorgano', methods=['POST'])
def evaluarorgano():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_recurso = request.form['id_recurso']
    tipo = request.form['id_tipo_evaluacion']
    resultado = request.form['id_resultado']
    obs = request.form['observaciones'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_evaluar_organo(%s,%s,%s,%s,%s,NULL)",
                    (id_recurso, session['id_personal'], tipo, resultado, obs))
        viabilidad = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('organos', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('organos', ok='Evaluación registrada, el órgano quedó ' + viabilidad))


# ======================================================
# CRUD 3: SOLICITUDES Y MATCHING
# ======================================================
@app.route('/solicitudes')
def solicitudes():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not (tiene('Registrar solicitudes') or tiene('Consultar compatibilidad')):
        return sin_permiso()

    estado = request.args.get('estado') or None
    urgencia = request.args.get('urgencia') or None
    recurso = request.args.get('recurso') or None
    buscar = request.args.get('q') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_solicitudes(%s, %s, %s, %s, %s, %s, NULL)",
                (ve_todo(), session['id_institucion'], estado, urgencia, recurso, buscar))
    cur.execute("FETCH ALL FROM cursor_solicitudes")
    Solicitudes = cur.fetchall()
    Estados = catalogo(cur, 'estados_solicitud')
    Urgencias = catalogo(cur, 'urgencias')
    cur.close()
    conexion.close()
    return render_template('solicitudes.html', Solicitudes=Solicitudes, Estados=Estados, Urgencias=Urgencias)


@app.route('/insertarsolicitud')
def insertarsolicitud():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar solicitudes'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    Receptores = catalogo(cur, 'receptores')
    Componentes = catalogo(cur, 'componentes')
    Urgencias = catalogo(cur, 'urgencias')
    TiposOrgano = catalogo(cur, 'tipos_organo')
    cur.close()
    conexion.close()
    return render_template('solicitud_nueva.html', Receptores=Receptores, Componentes=Componentes,
                           Urgencias=Urgencias, TiposOrgano=TiposOrgano)


@app.route('/registrasolicitud', methods=['POST'])
def registrasolicitud():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    receptor = request.form['id_receptor'] or None
    urgencia = request.form['id_urgencia'] or None
    componente = request.form['id_componente'] or None
    cantidad = request.form['cantidad'] or None
    horas = request.form['horas_limite'] or None
    motivo = request.form['motivo']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_solicitud_sangre(%s,%s,%s,%s,%s,%s,%s,NULL,NULL)",
                    (receptor, session['id_personal'], urgencia, componente, cantidad, horas, motivo))
        fila = cur.fetchone()
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('insertarsolicitud', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    texto = 'Solicitud ' + str(fila[0]) + ' registrada con ' + str(fila[1]) + ' candidatos compatibles'
    return redirect(url_for('solicitud', id_solicitud=fila[0], ok=texto))


@app.route('/registrasolicitudorgano', methods=['POST'])
def registrasolicitudorgano():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    receptor = request.form['id_receptor'] or None
    urgencia = request.form['id_urgencia'] or None
    organo = request.form['id_tipo_organo'] or None
    tam_min = request.form['tamano_min'] or None
    tam_max = request.form['tamano_max'] or None
    horas = request.form['horas_limite'] or None
    motivo = request.form['motivo']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_solicitud_organo(%s,%s,%s,%s,%s,%s,%s,%s,NULL,NULL)",
                    (receptor, session['id_personal'], urgencia, organo, tam_min, tam_max, horas, motivo))
        fila = cur.fetchone()
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('insertarsolicitud', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    texto = 'Solicitud ' + str(fila[0]) + ' registrada con ' + str(fila[1]) + ' órganos compatibles'
    return redirect(url_for('solicitud', id_solicitud=fila[0], ok=texto))


@app.route('/solicitud/<int:id_solicitud>')
def solicitud(id_solicitud):
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not (tiene('Registrar solicitudes') or tiene('Consultar compatibilidad')):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    try:
        # el procedimiento revisa que la solicitud sea de tu institucion
        cur.execute("CALL sp_obtener_solicitud(%s, %s, NULL, NULL, NULL)", (id_solicitud, session['id_personal']))
    except psycopg.Error as e:
        cur.close()
        conexion.close()
        return render_template('error.html', titulo='No se puede abrir la solicitud', mensaje=mensaje_error(e)), 403
    cur.execute("FETCH ALL FROM cursor_solicitud")
    Solicitud = cur.fetchone()
    cur.execute("FETCH ALL FROM cursor_lineas")
    Lineas = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_historial_matching")
    Historial = cur.fetchall()
    cur.close()
    conexion.close()
    return render_template('solicitud_detalle.html', Solicitud=Solicitud, Lineas=Lineas, Historial=Historial)


# Formulario de actualizar
@app.route('/editarsolicitud/<int:id_solicitud>', methods=['GET'])
def editarsolicitud(id_solicitud):
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Registrar solicitudes'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_obtener_solicitud(%s, %s, NULL, NULL, NULL)", (id_solicitud, session['id_personal']))
    except psycopg.Error as e:
        cur.close()
        conexion.close()
        return render_template('error.html', titulo='No se puede abrir la solicitud', mensaje=mensaje_error(e)), 403
    cur.execute("FETCH ALL FROM cursor_solicitud")
    Solicitud = cur.fetchone()
    Urgencias = catalogo(cur, 'urgencias')
    cur.close()
    conexion.close()

    # solo se modifican solicitudes En proceso (1) o Aprobadas (2)
    if Solicitud[3] not in (1, 2):
        return redirect(url_for('solicitud', id_solicitud=id_solicitud,
                                error='Solo se modifican solicitudes En proceso o Aprobadas'))
    return render_template('solicitud_form.html', Solicitud=Solicitud, Urgencias=Urgencias)


@app.route('/actualizarsolicitud', methods=['POST'])
def actualizarsolicitud():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_solicitud = request.form['id_solicitud']
    urgencia = request.form['id_urgencia'] or None
    limite = request.form['fecha_limite'] or None
    motivo = request.form['motivo']
    obs = request.form['observaciones'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_actualizar_solicitud(%s,%s,%s,%s,%s,%s)",
                    (id_solicitud, session['id_personal'], urgencia, limite, motivo, obs))
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('editarsolicitud', id_solicitud=id_solicitud, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('solicitud', id_solicitud=id_solicitud, ok='Solicitud ' + id_solicitud + ' actualizada'))


@app.route('/cancelarsolicitud', methods=['POST'])
def cancelarsolicitud():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_solicitud = request.form['id_solicitud']
    motivo = request.form['motivo']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        # baja logica: la solicitud queda Cancelada, no se borra
        cur.execute("CALL sp_cancelar_solicitud(%s,%s,%s,NULL)", (id_solicitud, session['id_personal'], motivo))
        liberados = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('solicitud', id_solicitud=id_solicitud, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    texto = 'Solicitud ' + id_solicitud + ' cancelada; ' + str(liberados) + ' recurso(s) regresaron a Disponible'
    return redirect(url_for('solicitud', id_solicitud=id_solicitud, ok=texto))


@app.route('/matching/<int:id_detalle>')
def matching(id_detalle):
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Consultar compatibilidad'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    try:
        # se recalcula el matching cada vez que se abre la pagina
        cur.execute("CALL sp_generar_matching(%s, NULL)", (id_detalle,))
        total = cur.fetchone()[0]
        cur.execute("CALL sp_obtener_candidatos(%s, %s, NULL, NULL)", (id_detalle, session['id_personal']))
        id_solicitud = cur.fetchone()[0]
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('solicitudes', error=mensaje_error(e)))
    cur.execute("FETCH ALL FROM cursor_candidatos")
    Candidatos = cur.fetchall()
    conexion.commit()
    cur.close()
    conexion.close()
    return render_template('matching.html', Candidatos=Candidatos, id_detalle=id_detalle,
                           id_solicitud=id_solicitud, total=total)


@app.route('/asignar', methods=['POST'])
def asignar():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_matching = request.form['id_matching']
    id_detalle = request.form['id_detalle']
    motivo = request.form['motivo']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_asignar_recurso(%s,%s,%s,NULL)", (id_matching, session['id_personal'], motivo))
        id_asignacion = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('matching', id_detalle=id_detalle, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('asignaciones', ok='Asignación ' + str(id_asignacion) + ' creada, el recurso quedó Reservado'))


# ======================================================
# ASIGNACIONES, TRASLADO, RECEPCION, TRANSFUSION Y TRASPLANTE
# ======================================================
@app.route('/asignaciones')
def asignaciones():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not (tiene('Aprobar asignaciones') or tiene('Gestionar traslados') or tiene('Confirmar recepciones')
            or tiene('Registrar utilización de recursos')):
        return sin_permiso()

    # coordinador regional y logistica ven toda la red; el hospital solo las suyas
    todo = ve_todo() or tiene('Gestionar traslados')

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_asignaciones(%s, %s, NULL)", (todo, session['id_institucion']))
    cur.execute("FETCH ALL FROM cursor_asignaciones")
    Asignaciones = cur.fetchall()
    Medios = catalogo(cur, 'medios_transporte')
    ResRecepcion = catalogo(cur, 'resultados_recepcion')
    ResTransfusion = catalogo(cur, 'resultados_transfusion')
    cur.close()
    conexion.close()
    return render_template('asignaciones.html', Asignaciones=Asignaciones, Medios=Medios,
                           ResRecepcion=ResRecepcion, ResTransfusion=ResTransfusion)


@app.route('/programartraslado', methods=['POST'])
def programartraslado():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_asignacion = request.form['id_asignacion']
    medio = request.form['id_medio']
    minutos = request.form['minutos'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_programar_traslado(%s,%s,%s,%s,NULL)",
                    (id_asignacion, session['id_personal'], medio, minutos))
        id_traslado = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('asignaciones', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('asignaciones', ok='Traslado ' + str(id_traslado) + ' en tránsito'))


@app.route('/registrarecepcion', methods=['POST'])
def registrarecepcion():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_traslado = request.form['id_traslado']
    resultado = request.form['id_resultado']
    obs = request.form['observaciones'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_recepcion(%s,%s,%s,%s,NULL)",
                    (id_traslado, session['id_personal'], resultado, obs))
        texto = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('asignaciones', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('asignaciones', ok='Traslado ' + id_traslado + ': ' + texto))


@app.route('/registratransfusion', methods=['POST'])
def registratransfusion():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_asignacion = request.form['id_asignacion']
    resultado = request.form['id_resultado']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_transfusion(%s,%s,%s,NULL)",
                    (id_asignacion, session['id_personal'], resultado))
        id_transfusion = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('asignaciones', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('asignaciones', ok='Transfusión ' + str(id_transfusion) + ' registrada'))


@app.route('/registratrasplante', methods=['POST'])
def registratrasplante():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_asignacion = request.form['id_asignacion']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_trasplante(%s,%s,NULL)", (id_asignacion, session['id_personal']))
        id_operacion = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('asignaciones', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('asignaciones', ok='Trasplante registrado (operación ' + str(id_operacion) + ')'))


# ======================================================
# TRASLADOS (vista_traslados)
# ======================================================
@app.route('/traslados')
def traslados():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not (tiene('Gestionar traslados') or tiene('Confirmar recepciones')):
        return sin_permiso()

    todo = ve_todo() or tiene('Gestionar traslados')
    estado = request.args.get('estado') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_traslados(%s, %s, %s, NULL)", (todo, session['id_institucion'], estado))
    cur.execute("FETCH ALL FROM cursor_traslados")
    Traslados = cur.fetchall()
    Estados = catalogo(cur, 'estados_traslado')
    cur.close()
    conexion.close()
    return render_template('traslados.html', Traslados=Traslados, Estados=Estados)


# ======================================================
# REPORTES (vista + CTE + funciones de ventana)
# ======================================================
@app.route('/reportes')
def reportes():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Consultar reportes regionales'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_reportes(NULL, NULL, NULL)")
    cur.execute("FETCH ALL FROM cursor_reporte_activas")
    Activas = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_aprovechamiento")
    Aprovechamiento = cur.fetchall()
    cur.execute("FETCH ALL FROM cursor_ranking")
    Ranking = cur.fetchall()
    cur.close()
    conexion.close()
    return render_template('reportes.html', Activas=Activas, Aprovechamiento=Aprovechamiento, Ranking=Ranking)


# ======================================================
# CRUD 2: PERSONAL Y USUARIOS
# ======================================================
@app.route('/personal')
def personal():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Gestionar usuarios y roles'):
        return sin_permiso()

    buscar = request.args.get('q') or None
    institucion = request.args.get('institucion') or None
    cargo = request.args.get('cargo') or None
    estado = request.args.get('estado') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_personal(%s, %s, %s, %s, NULL)", (buscar, institucion, cargo, estado))
    cur.execute("FETCH ALL FROM cursor_personal")
    Personal = cur.fetchall()
    Instituciones = catalogo(cur, 'instituciones')
    Cargos = catalogo(cur, 'cargos')
    Estados = catalogo(cur, 'estados_personal')
    cur.close()
    conexion.close()
    return render_template('personal.html', Personal=Personal, Instituciones=Instituciones,
                           Cargos=Cargos, Estados=Estados)


@app.route('/insertarpersonal')
def insertarpersonal():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Gestionar usuarios y roles'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    Sexos = catalogo(cur, 'sexos')
    Instituciones = catalogo(cur, 'instituciones_activas')
    Cargos = catalogo(cur, 'cargos')
    cur.close()
    conexion.close()
    return render_template('personal_form.html', Empleado=None, Sexos=Sexos, Instituciones=Instituciones,
                           Cargos=Cargos, Estados=[])


@app.route('/registrapersonal', methods=['POST'])
def registrapersonal():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    nombres = request.form['nombres']
    apellidos = request.form['apellidos']
    fecha_n = request.form['fecha_nacimiento'] or None
    sexo = request.form['id_sexo'] or None
    correo = request.form['correo'] or None
    tel = request.form['telefono'] or None
    institucion = request.form['id_institucion'] or None
    cargo = request.form['id_cargo'] or None
    cedula = request.form['cedula'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_registrar_personal(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,NULL)",
                    (nombres, apellidos, fecha_n, sexo, correo, tel, institucion, cargo, cedula,
                     session['id_personal']))
        id_personal = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('insertarpersonal', error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('empleado', id_personal=id_personal,
                            ok='Personal registrado con id ' + str(id_personal) + '. Ya le puedes crear su usuario'))


@app.route('/empleado/<int:id_personal>')
def empleado(id_personal):
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Gestionar usuarios y roles'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_personal_detalle(%s, NULL, NULL)", (id_personal,))
    cur.execute("FETCH ALL FROM cursor_empleado")
    Empleado = cur.fetchone()
    cur.execute("FETCH ALL FROM cursor_telefonos_empleado")
    Telefonos = cur.fetchall()
    Roles = catalogo(cur, 'roles')
    cur.close()
    conexion.close()

    if Empleado is None:
        return no_encontrado(None)
    return render_template('personal_detalle.html', Empleado=Empleado, Telefonos=Telefonos, Roles=Roles)


# Formulario de actualizar
@app.route('/editarpersonal/<int:id_personal>', methods=['GET'])
def editarpersonal(id_personal):
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))
    if not tiene('Gestionar usuarios y roles'):
        return sin_permiso()

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL sp_obtener_personal_detalle(%s, NULL, NULL)", (id_personal,))
    cur.execute("FETCH ALL FROM cursor_empleado")
    Empleado = cur.fetchone()
    Sexos = catalogo(cur, 'sexos')
    Instituciones = catalogo(cur, 'instituciones_activas')
    Cargos = catalogo(cur, 'cargos')
    Estados = catalogo(cur, 'estados_personal')
    cur.close()
    conexion.close()

    if Empleado is None:
        return no_encontrado(None)
    return render_template('personal_form.html', Empleado=Empleado, Sexos=Sexos, Instituciones=Instituciones,
                           Cargos=Cargos, Estados=Estados)


@app.route('/actualizarpersonal', methods=['POST'])
def actualizarpersonal():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_personal = request.form['id_personal']
    nombres = request.form['nombres']
    apellidos = request.form['apellidos']
    fecha_n = request.form['fecha_nacimiento'] or None
    sexo = request.form['id_sexo'] or None
    correo = request.form['correo'] or None
    tel = request.form['telefono'] or None
    institucion = request.form['id_institucion'] or None
    cargo = request.form['id_cargo'] or None
    cedula = request.form['cedula'] or None
    estado = request.form['id_estado_personal'] or None

    conexion = conectar()
    cur = conexion.cursor()
    try:
        cur.execute("CALL sp_actualizar_personal(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                    (id_personal, nombres, apellidos, fecha_n, sexo, correo, tel, institucion, cargo, cedula,
                     estado, session['id_personal']))
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('editarpersonal', id_personal=id_personal, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('empleado', id_personal=id_personal, ok='Datos del personal actualizados'))


@app.route('/borrarpersonal', methods=['POST'])
def borrarpersonal():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_personal = request.form['id_personal']

    conexion = conectar()
    cur = conexion.cursor()
    try:
        # si tiene registros en el historial no se borra: se da de baja (Inactivo)
        cur.execute("CALL sp_eliminar_personal(%s,%s,NULL)", (id_personal, session['id_personal']))
        resultado = cur.fetchone()[0]
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('empleado', id_personal=id_personal, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    if resultado == 'Eliminado':
        return redirect(url_for('personal', ok='Personal ' + id_personal + ' eliminado (no tenía registros)'))
    return redirect(url_for('empleado', id_personal=id_personal,
                            ok='Tiene registros en el historial, no se borra: baja lógica (personal y usuario Inactivos)'))


@app.route('/crearusuario', methods=['POST'])
def crearusuario():
    if 'id_usuario' not in session:
        return redirect(url_for('principal'))

    id_personal = request.form['id_personal']
    login = request.form['usuario_login']
    password = request.form['password']
    confirmar = request.form['confirmar']
    rol = request.form['id_rol'] or None

    if password != confirmar:
        return redirect(url_for('empleado', id_personal=id_personal, error='Las contraseñas no coinciden'))

    conexion = conectar()
    cur = conexion.cursor()
    try:
        # la contraseña se guarda como hash bcrypt dentro del procedimiento
        cur.execute("CALL sp_crear_usuario(%s,%s,%s,%s,%s)", (id_personal, login, password, rol, session['id_personal']))
        conexion.commit()
    except psycopg.Error as e:
        conexion.rollback()
        cur.close()
        conexion.close()
        return redirect(url_for('empleado', id_personal=id_personal, error=mensaje_error(e)))

    cur.close()
    conexion.close()
    return redirect(url_for('empleado', id_personal=id_personal, ok='Usuario ' + login + ' creado'))


if __name__ == '__main__':
    app.run(debug=True)
