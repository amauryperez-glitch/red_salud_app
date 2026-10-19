-- =====================================================================
-- 04_procedimientos.sql
-- Procedimientos almacenados (CREATE PROCEDURE, se ejecutan con CALL).
-- Ejecutar después de 03_funciones.sql:
--   sudo -u postgres psql < 04_procedimientos.sql
--
-- Son 16 procedimientos con los pasos del proceso de sangre y de órganos.
-- Los 16 se llaman desde Flask (app.py). Las funciones de apoyo (fn_*)
-- están en 03 y NO cuentan como procedimientos.
--
-- Cada procedimiento documenta: propósito, parámetros de entrada y salida,
-- tablas, reglas de negocio, manejo de excepciones, ejemplo de invocación
-- y resultado esperado. El resultado obtenido de cada caso está en
-- 07_resultado_pruebas.txt (salida de 07_pruebas_procedimientos.sql).
--
-- Manejo de excepciones (todos): cuando una regla no se cumple se lanza
-- RAISE EXCEPTION con un mensaje para el usuario; PostgreSQL deshace todo
-- lo que hizo el CALL y Flask muestra el mensaje y hace ROLLBACK.
--
-- Desde psql, los parámetros OUT se mandan como NULL en el CALL y el
-- resultado regresa como una fila (p. ej. CALL sp_x(1, 2, NULL);).
--
-- Valores de catálogos que se usan (vienen de 02_inserts):
--   cat_estados_recurso:   1 Disponible, 2 Reservado, 3 En traslado, 4 Utilizado, 5 Descartado
--   cat_estados_solicitud: 1 En proceso, 2 Aprobada, 3 Atendida, 4 Cancelada
--   cat_estados_asignacion:1 Activa, 2 Completada, 3 Cancelada
--   cat_estados_reserva:   1 Activa, 2 Liberada, 3 Cancelada, 4 Consumida
--   cat_estados_traslado:  1 Programado, 2 En tránsito, 3 Entregado
--   cat_estados_donacion:  1 Aceptada, 2 Completada, 3 Pendiente, 4 Rechazada
--   cat_tipos_movimiento_custodia: 1 Ingreso a almacenamiento, 2 Salida a traslado,
--                                  3 Recepción, 4 Entrega para uso, 5 Baja por descarte
-- =====================================================================
\set ON_ERROR_STOP on
\c banco_sangre_organos

-- ---------------------------------------------------------------------
-- SP1. sp_validar_login
-- Propósito:   Iniciar sesión. Revisa usuario y contraseña y regresa los datos de la sesión.
-- Parámetros:  IN  p_login     VARCHAR(50)   usuario (se compara en minúsculas)
--              IN  p_password  VARCHAR(100)  contraseña escrita por el usuario
--              OUT p_usuario   REFCURSOR     cursor 'cursor_login': 1 fila con id_usuario, id_personal,
--                                            nombre, cargo, id_institucion, institución, roles,
--                                            permisos (separados por ;), tipo de institución y servicios
-- Tablas:      usuarios, personal, personas, cat_cargos, instituciones, cat_tipos_instituciones,
--              usuario_rol, cat_roles, rol_permiso, cat_permisos, institucion_servicio, cat_servicios
-- Reglas:      La contraseña se valida contra el hash bcrypt (fn_verificar_password), nunca en texto.
--              Solo entran usuarios Activos, cuyo personal esté Activo y cuya institución esté Activa.
--              Si entra, se actualiza usuarios.ultimo_acceso.
-- Excepciones: No lanza error: si algo no coincide regresa el cursor vacío (0 filas) para no revelar
--              si lo que falló fue el usuario o la contraseña.
-- Invocación:  BEGIN; CALL sp_validar_login('tmedina', 'Demo2026!', NULL); FETCH ALL FROM cursor_login; COMMIT;
-- Esperado:    1 fila con los datos de Teresa Medina. Con contraseña incorrecta, o con lgomez
--              (Bloqueado) o crodriguez (Inactivo), 0 filas.
-- Flask:       /login
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_validar_login(
    IN p_login VARCHAR(50),
    IN p_password VARCHAR(100),
    OUT p_usuario REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_usuario INTEGER;
BEGIN
    p_usuario := 'cursor_login';

    SELECT u.id_usuario
    INTO v_id_usuario
    FROM usuarios u
    JOIN personal pe ON pe.id_personal = u.id_personal
    JOIN instituciones i ON i.id_institucion = pe.id_institucion
    WHERE u.usuario_login = lower(trim(p_login))
      AND fn_verificar_password(p_password, u.password_hash)   -- hash bcrypt (pgcrypto)
      AND u.id_estado_usuario = 1       -- usuario Activo
      AND pe.id_estado_personal = 1     -- personal Activo
      AND i.id_estado_institucion = 1;  -- institucion Activa

    IF v_id_usuario IS NOT NULL THEN
        UPDATE usuarios SET ultimo_acceso = now() WHERE id_usuario = v_id_usuario;

        OPEN p_usuario FOR
            SELECT u.id_usuario,
                   pe.id_personal,
                   p.nombres || ' ' || p.apellidos,
                   c.nombre,
                   pe.id_institucion,
                   i.nombre,
                   (SELECT string_agg(r.nombre, ', ')
                    FROM usuario_rol ur JOIN cat_roles r ON r.id_rol = ur.id_rol
                    WHERE ur.id_usuario = u.id_usuario),
                   (SELECT string_agg(DISTINCT cp.nombre, ';')
                    FROM usuario_rol ur
                    JOIN rol_permiso rp ON rp.id_rol = ur.id_rol
                    JOIN cat_permisos cp ON cp.id_permiso = rp.id_permiso
                    WHERE ur.id_usuario = u.id_usuario),
                   ti.nombre,
                   (SELECT string_agg(cs.nombre, ';')
                    FROM institucion_servicio isv
                    JOIN cat_servicios cs ON cs.id_servicio = isv.id_servicio
                    WHERE isv.id_institucion = i.id_institucion)
            FROM usuarios u
            JOIN personal pe ON pe.id_personal = u.id_personal
            JOIN personas p ON p.id_persona = pe.id_persona
            JOIN cat_cargos c ON c.id_cargo = pe.id_cargo
            JOIN instituciones i ON i.id_institucion = pe.id_institucion
            JOIN cat_tipos_instituciones ti ON ti.id_tipo_institucion = i.id_tipo_institucion
            WHERE u.id_usuario = v_id_usuario;
    ELSE
        -- cursor vacio: usuario o contraseña incorrectos
        OPEN p_usuario FOR SELECT 1 WHERE FALSE;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- SP2. sp_registrar_donante
-- Propósito:   Registrar un donante nuevo (persona + teléfono + donante) en una sola transacción.
-- Parámetros:  IN  p_nombres, p_apellidos VARCHAR(100); IN p_fecha_nacimiento DATE; IN p_id_sexo INTEGER;
--              IN  p_correo VARCHAR(150) (opcional); IN p_telefono VARCHAR(15) (opcional);
--              IN  p_id_tipo_sanguineo INTEGER; IN p_id_personal INTEGER (quien registra)
--              OUT p_id_donante INTEGER
-- Tablas:      personas, telefonos, donantes (lee personal, usuarios, rol_permiso, institucion_servicio)
-- Reglas:      Permiso 'Registrar donaciones'. La institución debe recibir donaciones de sangre o
--              procurar órganos. Nombre y apellidos obligatorios. Edad entre 18 y 65 años.
--              Teléfono de 10 a 15 dígitos. Correo con formato válido y sin repetir.
-- Excepciones: RAISE EXCEPTION por cada regla. unique_violation (correo repetido), check_violation
--              (formato) y foreign_key_violation (catálogo inexistente) se capturan y se cambian
--              por un mensaje claro.
-- Invocación:  CALL sp_registrar_donante('Mariana', 'Leal Garza', '1995-03-14', 1,
--                                        'mariana.leal@correo-demo.mx', '8112345678', 3, 5, NULL);
-- Esperado:    Regresa el id del donante nuevo (Activo). Con fecha 2012-01-01: ERROR "El donante
--              debe tener entre 18 y 65 años". Con personal 3 (Laboratorio): ERROR de permiso.
-- Flask:       /donantes/nuevo
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_donante(
    IN p_nombres VARCHAR(100),
    IN p_apellidos VARCHAR(100),
    IN p_fecha_nacimiento DATE,
    IN p_id_sexo INTEGER,
    IN p_correo VARCHAR(150),
    IN p_telefono VARCHAR(15),
    IN p_id_tipo_sanguineo INTEGER,
    IN p_id_personal INTEGER,
    OUT p_id_donante INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_persona INTEGER;
    v_edad INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar donaciones') THEN
        RAISE EXCEPTION 'No tienes permiso para registrar donantes';
    END IF;

    -- registran donantes los bancos de sangre y las instituciones que procuran organos
    IF NOT fn_institucion_ofrece((SELECT id_institucion FROM personal WHERE id_personal = p_id_personal), 1)
       AND NOT fn_institucion_ofrece((SELECT id_institucion FROM personal WHERE id_personal = p_id_personal), 4) THEN
        RAISE EXCEPTION 'Tu institución no recibe donaciones de sangre ni procura órganos';
    END IF;

    IF p_nombres IS NULL OR trim(p_nombres) = '' OR p_apellidos IS NULL OR trim(p_apellidos) = '' THEN
        RAISE EXCEPTION 'Nombre y apellidos son obligatorios';
    END IF;

    IF p_fecha_nacimiento IS NULL THEN
        RAISE EXCEPTION 'La fecha de nacimiento es obligatoria';
    END IF;

    v_edad := fn_calcular_edad(p_fecha_nacimiento);
    IF v_edad < 18 OR v_edad > 65 THEN
        RAISE EXCEPTION 'El donante debe tener entre 18 y 65 años (tiene %)', v_edad;
    END IF;

    IF p_telefono IS NOT NULL AND p_telefono !~ '^[0-9]{10,15}$' THEN
        RAISE EXCEPTION 'El teléfono debe tener de 10 a 15 dígitos, sin guiones';
    END IF;

    BEGIN
        INSERT INTO personas (id_sexo, nombres, apellidos, fecha_nacimiento, correo)
        VALUES (p_id_sexo, trim(p_nombres), trim(p_apellidos), p_fecha_nacimiento, lower(p_correo))
        RETURNING id_persona INTO v_id_persona;

        IF p_telefono IS NOT NULL THEN
            INSERT INTO telefonos (id_persona, telefono, id_tipo_telefono)
            VALUES (v_id_persona, p_telefono, 1);      -- 1 = Movil
        END IF;

        INSERT INTO donantes (id_persona, id_tipo_sanguineo, id_estado_donante)
        VALUES (v_id_persona, p_id_tipo_sanguineo, 1)   -- 1 = Activo
        RETURNING id_donante INTO p_id_donante;

    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Ya existe una persona registrada con el correo %', p_correo;
        WHEN check_violation THEN
            RAISE EXCEPTION 'Algún dato no tiene el formato correcto (revisa el correo)';
        WHEN foreign_key_violation THEN
            RAISE EXCEPTION 'El sexo o el tipo sanguíneo no existen en el catálogo';
    END;
END;
$$;


-- ---------------------------------------------------------------------
-- SP3. sp_registrar_donacion
-- Propósito:   Registrar una donación de sangre (queda Pendiente de laboratorio) junto con su
--              consentimiento informado.
-- Parámetros:  IN  p_id_donante INTEGER; IN p_id_personal INTEGER; IN p_volumen_ml INTEGER;
--              IN  p_folio_consentimiento VARCHAR(50); IN p_observaciones TEXT (opcional)
--              OUT p_id_donacion INTEGER
-- Tablas:      donaciones, documentos (lee donantes, personal, institucion_servicio)
-- Reglas:      Permiso 'Registrar donaciones'. Donante Activo. La institución del personal debe estar
--              Activa y ofrecer 'Donación de sangre' (regla 7.2). Volumen entre 400 y 500 ml.
--              Folio de consentimiento obligatorio y sin repetir. Mínimo 56 días desde la última
--              donación de sangre no rechazada.
-- Excepciones: RAISE EXCEPTION por cada regla (donante inexistente, no Activo, folio repetido, etc.).
-- Invocación:  CALL sp_registrar_donacion(1, 5, 450, 'CONS-P0001', NULL, NULL);
-- Esperado:    Regresa el id de la donación (estado Pendiente) y crea el documento Vigente.
--              Si el donante donó hace menos de 56 días: ERROR "deben pasar 56 días entre donaciones".
-- Flask:       /donaciones/registrar
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_donacion(
    IN p_id_donante INTEGER,
    IN p_id_personal INTEGER,
    IN p_volumen_ml INTEGER,
    IN p_folio_consentimiento VARCHAR(50),
    IN p_observaciones TEXT,
    OUT p_id_donacion INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_donante SMALLINT;
    v_id_institucion INTEGER;
    v_ultima TIMESTAMPTZ;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar donaciones') THEN
        RAISE EXCEPTION 'No tienes permiso para registrar donaciones';
    END IF;

    SELECT id_estado_donante INTO v_estado_donante
    FROM donantes WHERE id_donante = p_id_donante;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El donante % no existe', p_id_donante;
    END IF;

    IF v_estado_donante <> 1 THEN
        RAISE EXCEPTION 'El donante no está Activo, no puede donar';
    END IF;

    -- la donacion se registra en la institucion del personal que la captura
    SELECT id_institucion INTO v_id_institucion
    FROM personal WHERE id_personal = p_id_personal;

    IF NOT fn_institucion_ofrece(v_id_institucion, 1) THEN
        RAISE EXCEPTION 'Tu institución no está activa o no ofrece el servicio de donación de sangre';
    END IF;

    IF p_volumen_ml IS NULL OR p_volumen_ml < 400 OR p_volumen_ml > 500 THEN
        RAISE EXCEPTION 'El volumen debe estar entre 400 y 500 ml';
    END IF;

    IF p_folio_consentimiento IS NULL OR trim(p_folio_consentimiento) = '' THEN
        RAISE EXCEPTION 'El folio del consentimiento informado es obligatorio';
    END IF;

    IF EXISTS (SELECT 1 FROM documentos WHERE certificado_ref = upper(trim(p_folio_consentimiento))) THEN
        RAISE EXCEPTION 'Ya existe un documento con el folio %', upper(trim(p_folio_consentimiento));
    END IF;

    SELECT max(fecha_hora_inicio) INTO v_ultima
    FROM donaciones
    WHERE id_donante = p_id_donante
      AND id_tipo_donacion = 1            -- Sangre
      AND id_estado_donacion <> 4;        -- que no haya sido Rechazada

    IF v_ultima IS NOT NULL AND v_ultima > now() - INTERVAL '56 days' THEN
        RAISE EXCEPTION 'El donante donó el %, deben pasar 56 días entre donaciones',
            to_char(v_ultima, 'DD/MM/YYYY');
    END IF;

    INSERT INTO donaciones (id_donante, id_institucion, id_personal, id_estado_donacion,
                            id_tipo_donacion, fecha_hora_inicio, fecha_hora_fin, volumen_ml, observaciones)
    VALUES (p_id_donante, v_id_institucion, p_id_personal, 3,     -- 3 = Pendiente
            1, now(), now(), p_volumen_ml, p_observaciones)
    RETURNING id_donacion INTO p_id_donacion;

    -- consentimiento informado, queda Vigente hasta que un coordinador lo valide
    INSERT INTO documentos (id_tipo_documento, id_personal, id_donacion, certificado_ref, id_estado_documento)
    VALUES (1, p_id_personal, p_id_donacion, upper(trim(p_folio_consentimiento)), 1);
END;
$$;


-- ---------------------------------------------------------------------
-- SP4. sp_registrar_resultado_laboratorio
-- Propósito:   Capturar el tamizaje de una donación (muestra + 5 estudios) y liberar o rechazar la sangre.
-- Parámetros:  IN  p_id_donacion INTEGER; IN p_id_personal INTEGER;
--              IN  p_vih, p_hepatitis_b, p_hepatitis_c, p_sifilis VARCHAR(20) ('Reactivo' / 'No reactivo')
--              OUT p_resultado VARCHAR(20) ('Aceptada' o 'Rechazada')
-- Tablas:      muestras, estudios, estudios_persona, donaciones, donantes
-- Reglas:      Permiso 'Validar resultados de laboratorio'. La institución debe tener Laboratorio
--              clínico. Solo donaciones de sangre en estado Pendiente. Si algún estudio es Reactivo
--              la donación se Rechaza y el donante queda Diferido; si todos son No reactivo queda
--              Aceptada (regla 8.10). Folio de muestra automático (regla 11.1).
-- Excepciones: RAISE EXCEPTION si el valor no es Reactivo/No reactivo, la donación no existe o ya
--              tiene resultado, o no hay permiso.
-- Invocación:  CALL sp_registrar_resultado_laboratorio(80, 3, 'No reactivo', 'No reactivo',
--                                                      'No reactivo', 'No reactivo', NULL);
-- Esperado:    'Aceptada'. Con algún 'Reactivo': 'Rechazada' y donante Diferido. Repetirlo: ERROR
--              "La donación ya tiene resultado".
-- Flask:       /donaciones/resultado
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_resultado_laboratorio(
    IN p_id_donacion INTEGER,
    IN p_id_personal INTEGER,
    IN p_vih VARCHAR(20),
    IN p_hepatitis_b VARCHAR(20),
    IN p_hepatitis_c VARCHAR(20),
    IN p_sifilis VARCHAR(20),
    OUT p_resultado VARCHAR(20)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado SMALLINT;
    v_tipo SMALLINT;
    v_id_donante INTEGER;
    v_id_persona INTEGER;
    v_tipo_sangre VARCHAR(5);
    v_id_institucion INTEGER;
    v_id_muestra INTEGER;
    v_id_estudio INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Validar resultados de laboratorio') THEN
        RAISE EXCEPTION 'No tienes permiso para validar resultados de laboratorio';
    END IF;

    -- solo se aceptan estos dos valores
    IF p_vih NOT IN ('Reactivo', 'No reactivo') OR p_hepatitis_b NOT IN ('Reactivo', 'No reactivo')
       OR p_hepatitis_c NOT IN ('Reactivo', 'No reactivo') OR p_sifilis NOT IN ('Reactivo', 'No reactivo') THEN
        RAISE EXCEPTION 'Cada resultado debe ser Reactivo o No reactivo';
    END IF;

    SELECT d.id_estado_donacion, d.id_tipo_donacion, d.id_donante, dn.id_persona, ts.nombre
    INTO v_estado, v_tipo, v_id_donante, v_id_persona, v_tipo_sangre
    FROM donaciones d
    JOIN donantes dn ON dn.id_donante = d.id_donante
    JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = dn.id_tipo_sanguineo
    WHERE d.id_donacion = p_id_donacion;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La donación % no existe', p_id_donacion;
    END IF;

    IF v_tipo <> 1 THEN
        RAISE EXCEPTION 'Este procedimiento es solo para donaciones de sangre';
    END IF;

    IF v_estado <> 3 THEN
        RAISE EXCEPTION 'La donación ya tiene resultado (no está Pendiente)';
    END IF;

    SELECT id_institucion INTO v_id_institucion FROM personal WHERE id_personal = p_id_personal;

    IF NOT fn_institucion_ofrece(v_id_institucion, 5) THEN
        RAISE EXCEPTION 'Tu institución no ofrece laboratorio clínico';
    END IF;

    -- muestra de sangre del donante (folio automatico, regla 11.1)
    INSERT INTO muestras (id_tipo_muestra, id_persona, id_institucion, id_personal, id_recurso,
                          fecha_hora_toma, folio, id_condicion_muestra, observaciones)
    VALUES (1, v_id_persona, v_id_institucion, p_id_personal, NULL,
            now(), 'M-D' || lpad(p_id_donacion::TEXT, 5, '0'), 1,
            'Muestra para tamizaje de la donacion ' || p_id_donacion)
    RETURNING id_muestra INTO v_id_muestra;

    -- 1 ABO/Rh
    INSERT INTO estudios (id_tipo_estudio, id_estado_estudio, id_institucion, id_personal, id_muestra,
                          fecha_hora_inicio, fecha_hora_fin, resultado)
    VALUES (1, 1, v_id_institucion, p_id_personal, v_id_muestra, now(), now(), v_tipo_sangre)
    RETURNING id_estudio INTO v_id_estudio;
    INSERT INTO estudios_persona VALUES (v_id_estudio, v_id_persona);

    -- 2 VIH
    INSERT INTO estudios (id_tipo_estudio, id_estado_estudio, id_institucion, id_personal, id_muestra,
                          fecha_hora_inicio, fecha_hora_fin, resultado)
    VALUES (2, 1, v_id_institucion, p_id_personal, v_id_muestra, now(), now(), p_vih)
    RETURNING id_estudio INTO v_id_estudio;
    INSERT INTO estudios_persona VALUES (v_id_estudio, v_id_persona);

    -- 3 Hepatitis B
    INSERT INTO estudios (id_tipo_estudio, id_estado_estudio, id_institucion, id_personal, id_muestra,
                          fecha_hora_inicio, fecha_hora_fin, resultado)
    VALUES (3, 1, v_id_institucion, p_id_personal, v_id_muestra, now(), now(), p_hepatitis_b)
    RETURNING id_estudio INTO v_id_estudio;
    INSERT INTO estudios_persona VALUES (v_id_estudio, v_id_persona);

    -- 4 Hepatitis C
    INSERT INTO estudios (id_tipo_estudio, id_estado_estudio, id_institucion, id_personal, id_muestra,
                          fecha_hora_inicio, fecha_hora_fin, resultado)
    VALUES (4, 1, v_id_institucion, p_id_personal, v_id_muestra, now(), now(), p_hepatitis_c)
    RETURNING id_estudio INTO v_id_estudio;
    INSERT INTO estudios_persona VALUES (v_id_estudio, v_id_persona);

    -- 5 Sifilis
    INSERT INTO estudios (id_tipo_estudio, id_estado_estudio, id_institucion, id_personal, id_muestra,
                          fecha_hora_inicio, fecha_hora_fin, resultado)
    VALUES (5, 1, v_id_institucion, p_id_personal, v_id_muestra, now(), now(), p_sifilis)
    RETURNING id_estudio INTO v_id_estudio;
    INSERT INTO estudios_persona VALUES (v_id_estudio, v_id_persona);

    IF p_vih = 'Reactivo' OR p_hepatitis_b = 'Reactivo' OR p_hepatitis_c = 'Reactivo' OR p_sifilis = 'Reactivo' THEN
        UPDATE donaciones SET id_estado_donacion = 4 WHERE id_donacion = p_id_donacion;   -- Rechazada
        UPDATE donantes SET id_estado_donante = 3 WHERE id_donante = v_id_donante;       -- Diferido
        p_resultado := 'Rechazada';
    ELSE
        UPDATE donaciones SET id_estado_donacion = 1 WHERE id_donacion = p_id_donacion;   -- Aceptada
        p_resultado := 'Aceptada';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- SP5. sp_fraccionar_donacion
-- Propósito:   Separar una donación Aceptada en sus 3 componentes y meterlos al inventario.
-- Parámetros:  IN  p_id_donacion INTEGER; IN p_id_personal INTEGER
--              OUT p_total INTEGER (unidades creadas)
-- Tablas:      recursos, unidades_componentes_sanguineos, almacenamientos_recurso, custodias_recurso,
--              donaciones
-- Reglas:      Permiso 'Registrar estudios'. Solo donaciones Aceptadas. Caducidad: eritrocitos 42 días,
--              plasma 365, plaquetas 5 (regla 8.3: caducidad > extracción). Folio automático
--              UC-#####-E/P/PL. Cada unidad queda Disponible, almacenada y con custodia de ingreso.
--              La donación pasa a Completada.
-- Excepciones: RAISE EXCEPTION si la donación no existe, no está Aceptada o no hay permiso.
-- Invocación:  CALL sp_fraccionar_donacion(80, 3, NULL);
-- Esperado:    3. Repetirlo: ERROR "Solo se fraccionan donaciones Aceptadas por laboratorio".
-- Flask:       /donaciones/fraccionar
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_fraccionar_donacion(
    IN p_id_donacion INTEGER,
    IN p_id_personal INTEGER,
    OUT p_total INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado SMALLINT;
    v_id_institucion INTEGER;
    v_id_tipo_sanguineo SMALLINT;
    v_fecha TIMESTAMPTZ;
    v_id_recurso INTEGER;
    v_componente SMALLINT;
    v_dias INTEGER;
    v_sufijo VARCHAR(3);
    v_almacen SMALLINT;
    v_temp NUMERIC;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar estudios') THEN
        RAISE EXCEPTION 'No tienes permiso para fraccionar donaciones';
    END IF;

    SELECT d.id_estado_donacion, d.id_institucion, dn.id_tipo_sanguineo, d.fecha_hora_inicio
    INTO v_estado, v_id_institucion, v_id_tipo_sanguineo, v_fecha
    FROM donaciones d
    JOIN donantes dn ON dn.id_donante = d.id_donante
    WHERE d.id_donacion = p_id_donacion;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La donación % no existe', p_id_donacion;
    END IF;

    IF v_estado <> 1 THEN
        RAISE EXCEPTION 'Solo se fraccionan donaciones Aceptadas por laboratorio';
    END IF;

    p_total := 0;

    FOR v_componente IN 1..3 LOOP
        IF v_componente = 1 THEN
            v_dias := 42;  v_sufijo := 'E';  v_almacen := 1; v_temp := 4;     -- eritrocitos, refrigeracion
        ELSIF v_componente = 2 THEN
            v_dias := 365; v_sufijo := 'P';  v_almacen := 2; v_temp := -30;   -- plasma, congelacion
        ELSE
            v_dias := 5;   v_sufijo := 'PL'; v_almacen := 4; v_temp := 22;    -- plaquetas, agitacion
        END IF;

        INSERT INTO recursos (id_tipo_recurso, id_institucion, id_tipo_sanguineo, id_estado_recurso,
                              fecha_hora_origen, folio, observaciones)
        VALUES (1, v_id_institucion, v_id_tipo_sanguineo, 1, v_fecha,
                'UC-' || lpad(p_id_donacion::TEXT, 5, '0') || '-' || v_sufijo,
                'Fraccionado de la donacion ' || p_id_donacion)
        RETURNING id_recurso INTO v_id_recurso;

        INSERT INTO unidades_componentes_sanguineos (id_recurso, id_donacion, id_componente, fecha_hora_caducidad)
        VALUES (v_id_recurso, p_id_donacion, v_componente, v_fecha + (v_dias || ' days')::INTERVAL);

        INSERT INTO almacenamientos_recurso (id_recurso, id_tipo_almacenamiento, fecha_hora_inicio,
                                             temperatura_registrada, id_personal)
        VALUES (v_id_recurso, v_almacen, now(), v_temp, p_id_personal);

        INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal,
                                       id_tipo_movimiento_custodia, fecha_hora)
        VALUES (v_id_recurso, v_id_institucion, p_id_personal, 1, now());   -- Ingreso a almacenamiento

        p_total := p_total + 1;
    END LOOP;

    UPDATE donaciones SET id_estado_donacion = 2 WHERE id_donacion = p_id_donacion;  -- Completada
END;
$$;


-- ---------------------------------------------------------------------
-- SP6. sp_generar_matching
-- Propósito:   Buscar los recursos compatibles para una línea de solicitud (sangre u órgano) y
--              guardarlos como candidatos.
-- Parámetros:  IN  p_id_solicitud_detalle INTEGER
--              OUT p_total INTEGER (candidatos disponibles)
-- Tablas:      matching (lee solicitudes, solicitudes_detalle, requisitos_sangre, requisitos_organo,
--              receptores, recursos, unidades_componentes_sanguineos, organos, instituciones, reservas)
-- Reglas:      Sangre: mismo componente, Disponible, vigente, institución Activa, sin reserva activa
--              y ABO/Rh compatible (fn_compatible_sangre, reglas 7.10 y 8.6).
--              Órgano: mismo tipo, Disponible, Viable, vigente, ABO compatible y tamaño en el rango.
--              Los candidatos que ya no sirven se marcan disponible = false. Sin candidatos: 0
--              (caso excepcional 12.1). El orden lo da fn_puntaje_matching (regla 7.11).
-- Excepciones: RAISE EXCEPTION si la línea no existe o la solicitud ya está Atendida/Cancelada.
-- Invocación:  CALL sp_generar_matching(1, NULL);
-- Esperado:    Número de candidatos compatibles (puede ser 0).
-- Flask:       /matching/<id_detalle> (y desde SP7 y SP14)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_generar_matching(
    IN p_id_solicitud_detalle INTEGER,
    OUT p_total INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo_recurso SMALLINT;
    v_estado_solicitud SMALLINT;
    v_tipo_receptor VARCHAR(5);
    v_id_componente SMALLINT;
    v_id_tipo_organo SMALLINT;
    v_tam_min NUMERIC;
    v_tam_max NUMERIC;
BEGIN
    SELECT sd.id_tipo_recurso, s.id_estado_solicitud, ts.nombre
    INTO v_tipo_recurso, v_estado_solicitud, v_tipo_receptor
    FROM solicitudes_detalle sd
    JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
    JOIN receptores rc ON rc.id_receptor = s.id_receptor
    JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = rc.id_tipo_sanguineo
    WHERE sd.id_solicitud_detalle = p_id_solicitud_detalle;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La línea de solicitud % no existe', p_id_solicitud_detalle;
    END IF;

    IF v_estado_solicitud IN (3, 4) THEN
        RAISE EXCEPTION 'La solicitud ya está Atendida o Cancelada';
    END IF;

    IF v_tipo_recurso = 1 THEN
        -- ===== SANGRE =====
        SELECT id_componente INTO v_id_componente
        FROM requisitos_sangre WHERE id_solicitud_detalle = p_id_solicitud_detalle;

        -- apagar los candidatos viejos que ya no estan disponibles o caducaron
        UPDATE matching m
        SET disponible = FALSE
        FROM recursos r, unidades_componentes_sanguineos u
        WHERE r.id_recurso = m.id_recurso
          AND u.id_recurso = m.id_recurso
          AND m.id_solicitud_detalle = p_id_solicitud_detalle
          AND (r.id_estado_recurso <> 1 OR u.fecha_hora_caducidad <= now());

        -- insertar (o refrescar) los candidatos compatibles
        INSERT INTO matching (id_solicitud_detalle, id_recurso, id_resultado_compatibilidad,
                              disponible, explicacion, fecha_hora_calculo)
        SELECT p_id_solicitud_detalle, r.id_recurso, 1, TRUE,
               ts.nombre || ' compatible con receptor ' || v_tipo_receptor
               || '; caduca ' || to_char(u.fecha_hora_caducidad, 'DD/MM/YYYY'),
               now()
        FROM recursos r
        JOIN unidades_componentes_sanguineos u ON u.id_recurso = r.id_recurso
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
        JOIN instituciones i ON i.id_institucion = r.id_institucion
        WHERE r.id_estado_recurso = 1
          AND u.id_componente = v_id_componente
          AND u.fecha_hora_caducidad > now()
          AND i.id_estado_institucion = 1
          AND fn_compatible_sangre(ts.nombre, v_tipo_receptor, v_id_componente)
          AND NOT EXISTS (SELECT 1 FROM reservas rv
                          WHERE rv.id_recurso = r.id_recurso AND rv.id_estado_reserva = 1)
        ON CONFLICT (id_solicitud_detalle, id_recurso)
        DO UPDATE SET disponible = TRUE,
                      id_resultado_compatibilidad = 1,
                      explicacion = EXCLUDED.explicacion,
                      fecha_hora_calculo = now();
    ELSE
        -- ===== ORGANO =====
        SELECT id_tipo_organo, tamano_minimo_cm, tamano_maximo_cm
        INTO v_id_tipo_organo, v_tam_min, v_tam_max
        FROM requisitos_organo WHERE id_solicitud_detalle = p_id_solicitud_detalle;

        UPDATE matching m
        SET disponible = FALSE
        FROM recursos r, organos o
        WHERE r.id_recurso = m.id_recurso
          AND o.id_recurso = m.id_recurso
          AND m.id_solicitud_detalle = p_id_solicitud_detalle
          AND (r.id_estado_recurso <> 1 OR o.id_viabilidad_organo <> 1 OR o.fecha_hora_caducidad <= now());

        INSERT INTO matching (id_solicitud_detalle, id_recurso, id_resultado_compatibilidad,
                              disponible, explicacion, fecha_hora_calculo)
        SELECT p_id_solicitud_detalle, r.id_recurso, 1, TRUE,
               co.nombre || ' ' || ts.nombre || ' compatible con receptor ' || v_tipo_receptor
               || COALESCE('; mide ' || o.tamano_cm || ' cm', '')
               || '; viable hasta ' || to_char(o.fecha_hora_caducidad, 'DD/MM/YYYY HH24:MI'),
               now()
        FROM recursos r
        JOIN organos o ON o.id_recurso = r.id_recurso
        JOIN cat_organos co ON co.id_tipo_organo = o.id_tipo_organo
        JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
        JOIN instituciones i ON i.id_institucion = r.id_institucion
        WHERE r.id_estado_recurso = 1
          AND o.id_viabilidad_organo = 1
          AND o.id_tipo_organo = v_id_tipo_organo
          AND o.fecha_hora_caducidad > now()
          AND i.id_estado_institucion = 1
          AND fn_compatible_sangre(ts.nombre, v_tipo_receptor, 0)
          AND (v_tam_min IS NULL OR o.tamano_cm >= v_tam_min)
          AND (v_tam_max IS NULL OR o.tamano_cm <= v_tam_max)
          AND NOT EXISTS (SELECT 1 FROM reservas rv
                          WHERE rv.id_recurso = r.id_recurso AND rv.id_estado_reserva = 1)
        ON CONFLICT (id_solicitud_detalle, id_recurso)
        DO UPDATE SET disponible = TRUE,
                      id_resultado_compatibilidad = 1,
                      explicacion = EXCLUDED.explicacion,
                      fecha_hora_calculo = now();
    END IF;

    SELECT count(*) INTO p_total
    FROM matching
    WHERE id_solicitud_detalle = p_id_solicitud_detalle
      AND disponible = TRUE
      AND id_resultado_compatibilidad = 1;
END;
$$;


-- ---------------------------------------------------------------------
-- SP7. sp_registrar_solicitud_sangre
-- Propósito:   El hospital pide componentes sanguíneos para un receptor; busca candidatos al momento.
-- Parámetros:  IN  p_id_receptor INTEGER; IN p_id_personal INTEGER; IN p_id_urgencia INTEGER;
--              IN  p_id_componente INTEGER; IN p_cantidad INTEGER; IN p_horas_limite INTEGER;
--              IN  p_motivo VARCHAR(255)
--              OUT p_id_solicitud INTEGER; OUT p_candidatos INTEGER
-- Tablas:      solicitudes, solicitudes_detalle, requisitos_sangre, matching (vía SP6)
-- Reglas:      Permiso 'Registrar solicitudes'. Solo un Hospital Activo con servicio de Transfusión
--              (reglas 7.2, 7.7). Receptor registrado y no Inactivo. Cantidad > 0, motivo
--              obligatorio, horas límite > 0. El tipo de sangre se toma del receptor. Llama a
--              sp_generar_matching (búsqueda automática, regla 11.3).
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_registrar_solicitud_sangre(1, 6, 1, 1, 1, 24, 'Cirugía programada', NULL, NULL);
-- Esperado:    (id de la solicitud, candidatos). Con personal de banco de sangre: ERROR "Solo un
--              hospital activo con servicio de transfusión puede pedir sangre".
-- Flask:       /solicitudes/nueva (formulario de sangre)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_solicitud_sangre(
    IN p_id_receptor INTEGER,
    IN p_id_personal INTEGER,
    IN p_id_urgencia INTEGER,
    IN p_id_componente INTEGER,
    IN p_cantidad INTEGER,
    IN p_horas_limite INTEGER,
    IN p_motivo VARCHAR(255),
    OUT p_id_solicitud INTEGER,
    OUT p_candidatos INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_hospital INTEGER;
    v_tipo_hospital SMALLINT;
    v_estado_receptor SMALLINT;
    v_tipo_sangre SMALLINT;
    v_id_detalle INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar solicitudes') THEN
        RAISE EXCEPTION 'No tienes permiso para registrar solicitudes';
    END IF;

    SELECT pe.id_institucion, i.id_tipo_institucion
    INTO v_id_hospital, v_tipo_hospital
    FROM personal pe
    JOIN instituciones i ON i.id_institucion = pe.id_institucion
    WHERE pe.id_personal = p_id_personal;

    IF v_tipo_hospital <> 2 OR NOT fn_institucion_ofrece(v_id_hospital, 2) THEN
        RAISE EXCEPTION 'Solo un hospital activo con servicio de transfusión puede pedir sangre';
    END IF;

    SELECT id_estado_receptor, id_tipo_sanguineo INTO v_estado_receptor, v_tipo_sangre
    FROM receptores WHERE id_receptor = p_id_receptor;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El receptor % no está registrado', p_id_receptor;
    END IF;

    IF v_estado_receptor = 2 THEN
        RAISE EXCEPTION 'El receptor está Inactivo';
    END IF;

    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor que cero';
    END IF;

    IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
        RAISE EXCEPTION 'El motivo es obligatorio';
    END IF;

    IF p_horas_limite IS NULL OR p_horas_limite <= 0 THEN
        RAISE EXCEPTION 'Las horas límite deben ser mayores que cero';
    END IF;

    INSERT INTO solicitudes (id_hospital, id_receptor, id_personal, id_urgencia, id_estado_solicitud,
                             fecha_hora_solicitud, fecha_limite, motivo)
    VALUES (v_id_hospital, p_id_receptor, p_id_personal, p_id_urgencia, 1,      -- En proceso
            now(), now() + (p_horas_limite || ' hours')::INTERVAL, trim(p_motivo))
    RETURNING id_solicitud INTO p_id_solicitud;

    INSERT INTO solicitudes_detalle (id_solicitud, id_tipo_recurso, cantidad)
    VALUES (p_id_solicitud, 1, p_cantidad)
    RETURNING id_solicitud_detalle INTO v_id_detalle;

    INSERT INTO requisitos_sangre (id_solicitud_detalle, id_componente, id_tipo_sanguineo)
    VALUES (v_id_detalle, p_id_componente, v_tipo_sangre);

    -- busqueda automatica de candidatos
    CALL sp_generar_matching(v_id_detalle, p_candidatos);
END;
$$;


-- ---------------------------------------------------------------------
-- SP8. sp_asignar_recurso
-- Propósito:   Confirmar un candidato del matching: crea la asignación y la reserva del recurso.
-- Parámetros:  IN  p_id_matching INTEGER; IN p_id_personal INTEGER; IN p_motivo VARCHAR(255)
--              OUT p_id_asignacion INTEGER
-- Tablas:      asignaciones, reservas, recursos, solicitudes (lee matching, solicitudes_detalle)
-- Reglas:      Permiso 'Aprobar asignaciones' (regla 8.14). Motivo obligatorio. Candidato Compatible,
--              solicitud En proceso/Aprobada, recurso Disponible y vigente, sin otra asignación
--              activa, y sin pasar la cantidad pedida. Recurso -> Reservado, solicitud -> Aprobada.
--              Una sola reserva activa por recurso (regla 7.4, índice uq_reservas_recurso_activa).
-- Excepciones: RAISE EXCEPTION por cada regla. Si dos usuarios reservan a la vez, la unique_violation
--              del índice se captura: "Otra persona acaba de reservar este recurso" (caso 12.8).
-- Invocación:  CALL sp_asignar_recurso(250, 2, 'Mejor puntaje y caducidad más próxima', NULL);
-- Esperado:    Id de la asignación. Repetirlo con el mismo recurso: ERROR "El recurso ya no está Disponible".
-- Flask:       /asignar
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_asignar_recurso(
    IN p_id_matching INTEGER,
    IN p_id_personal INTEGER,
    IN p_motivo VARCHAR(255),
    OUT p_id_asignacion INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_recurso INTEGER;
    v_id_detalle INTEGER;
    v_resultado SMALLINT;
    v_estado_recurso SMALLINT;
    v_id_solicitud INTEGER;
    v_estado_solicitud SMALLINT;
    v_cantidad INTEGER;
    v_asignadas INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Aprobar asignaciones') THEN
        RAISE EXCEPTION 'No tienes permiso para aprobar asignaciones';
    END IF;

    -- toda asignacion debe tener justificacion
    IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
        RAISE EXCEPTION 'Escribe el motivo de la asignación';
    END IF;

    SELECT m.id_recurso, m.id_solicitud_detalle, m.id_resultado_compatibilidad,
           r.id_estado_recurso, sd.id_solicitud, s.id_estado_solicitud, sd.cantidad
    INTO v_id_recurso, v_id_detalle, v_resultado,
         v_estado_recurso, v_id_solicitud, v_estado_solicitud, v_cantidad
    FROM matching m
    JOIN recursos r ON r.id_recurso = m.id_recurso
    JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
    JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
    WHERE m.id_matching = p_id_matching;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El matching % no existe', p_id_matching;
    END IF;

    IF v_resultado <> 1 THEN
        RAISE EXCEPTION 'El recurso no es compatible, no se puede asignar';
    END IF;

    IF v_estado_solicitud NOT IN (1, 2) THEN
        RAISE EXCEPTION 'La solicitud ya está Atendida o Cancelada';
    END IF;

    IF v_estado_recurso <> 1 THEN
        RAISE EXCEPTION 'El recurso ya no está Disponible';
    END IF;

    IF fn_dias_restantes(v_id_recurso) <= 0 THEN
        RAISE EXCEPTION 'El recurso ya caducó';
    END IF;

    IF EXISTS (SELECT 1 FROM asignaciones WHERE id_recurso = v_id_recurso AND id_estado_asignacion = 1) THEN
        RAISE EXCEPTION 'El recurso ya tiene una asignación activa';
    END IF;

    -- no asignar mas unidades de las que se pidieron
    SELECT count(*) INTO v_asignadas
    FROM asignaciones a
    JOIN matching m ON m.id_matching = a.id_matching
    WHERE m.id_solicitud_detalle = v_id_detalle
      AND a.id_estado_asignacion IN (1, 2);

    IF v_asignadas >= v_cantidad THEN
        RAISE EXCEPTION 'Esta línea ya tiene las % unidades que pidió', v_cantidad;
    END IF;

    BEGIN
        INSERT INTO asignaciones (id_matching, id_recurso, id_personal, id_estado_asignacion,
                                  fecha_hora_asignacion, motivo)
        VALUES (p_id_matching, v_id_recurso, p_id_personal, 1, now(),
                trim(p_motivo))
        RETURNING id_asignacion INTO p_id_asignacion;

        INSERT INTO reservas (id_asignacion, id_recurso, id_personal, id_estado_reserva, fecha_hora_inicio)
        VALUES (p_id_asignacion, v_id_recurso, p_id_personal, 1, now());
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Otra persona acaba de reservar este recurso, recalcula el matching';
    END;

    UPDATE recursos SET id_estado_recurso = 2 WHERE id_recurso = v_id_recurso;          -- Reservado
    UPDATE solicitudes SET id_estado_solicitud = 2 WHERE id_solicitud = v_id_solicitud; -- Aprobada
END;
$$;


-- ---------------------------------------------------------------------
-- SP9. sp_programar_traslado
-- Propósito:   Logística registra la salida del recurso reservado hacia la institución que lo pidió.
-- Parámetros:  IN  p_id_asignacion INTEGER; IN p_id_personal INTEGER; IN p_id_medio_transporte INTEGER;
--              IN  p_minutos_estimados INTEGER
--              OUT p_id_traslado INTEGER
-- Tablas:      traslados, traslado_detalle, custodias_recurso, recursos
-- Reglas:      Permiso 'Gestionar traslados'. Asignación Activa y recurso Reservado y vigente. Origen y
--              destino diferentes (regla 8.12); llegada estimada >= salida (regla 8.13). El traslado
--              queda En tránsito, se registra la custodia de salida y el recurso pasa a En traslado.
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_programar_traslado(109, 4, 1, 40, NULL);
-- Esperado:    Id del traslado. Con un recurso que ya está en el hospital: ERROR "no necesita traslado".
-- Flask:       /asignaciones/traslado
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_programar_traslado(
    IN p_id_asignacion INTEGER,
    IN p_id_personal INTEGER,
    IN p_id_medio_transporte INTEGER,
    IN p_minutos_estimados INTEGER,
    OUT p_id_traslado INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_recurso INTEGER;
    v_estado_asig SMALLINT;
    v_estado_recurso SMALLINT;
    v_origen INTEGER;
    v_destino INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Gestionar traslados') THEN
        RAISE EXCEPTION 'No tienes permiso para gestionar traslados';
    END IF;

    SELECT a.id_recurso, a.id_estado_asignacion, r.id_estado_recurso, r.id_institucion, s.id_hospital
    INTO v_id_recurso, v_estado_asig, v_estado_recurso, v_origen, v_destino
    FROM asignaciones a
    JOIN recursos r ON r.id_recurso = a.id_recurso
    JOIN matching m ON m.id_matching = a.id_matching
    JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
    JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
    WHERE a.id_asignacion = p_id_asignacion;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La asignación % no existe', p_id_asignacion;
    END IF;

    IF v_estado_asig <> 1 THEN
        RAISE EXCEPTION 'La asignación no está Activa';
    END IF;

    IF v_estado_recurso <> 2 THEN
        RAISE EXCEPTION 'El recurso debe estar Reservado para trasladarse';
    END IF;

    IF v_origen = v_destino THEN
        RAISE EXCEPTION 'El recurso ya está en el hospital destino, no necesita traslado';
    END IF;

    IF fn_dias_restantes(v_id_recurso) <= 0 THEN
        RAISE EXCEPTION 'El recurso ya caducó, no se puede enviar';
    END IF;

    IF p_minutos_estimados IS NULL OR p_minutos_estimados <= 0 THEN
        RAISE EXCEPTION 'El tiempo estimado debe ser mayor que cero';
    END IF;

    INSERT INTO traslados (id_institucion_origen, id_institucion_destino, id_personal, fecha_salida,
                           fecha_estimada_llegada, id_estado_traslado, id_medio_transporte)
    VALUES (v_origen, v_destino, p_id_personal, now(),
            now() + (p_minutos_estimados || ' minutes')::INTERVAL, 2, p_id_medio_transporte)  -- En transito
    RETURNING id_traslado INTO p_id_traslado;

    INSERT INTO traslado_detalle (id_traslado, id_asignacion) VALUES (p_id_traslado, p_id_asignacion);

    INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal,
                                   id_tipo_movimiento_custodia, fecha_hora, id_traslado)
    VALUES (v_id_recurso, v_origen, p_id_personal, 2, now(), p_id_traslado);    -- Salida a traslado

    UPDATE recursos SET id_estado_recurso = 3 WHERE id_recurso = v_id_recurso;  -- En traslado
END;
$$;


-- ---------------------------------------------------------------------
-- SP10. sp_registrar_recepcion
-- Propósito:   Confirmar la llegada de un traslado; si llega mal, el recurso se da de baja.
-- Parámetros:  IN  p_id_traslado INTEGER; IN p_id_personal INTEGER; IN p_id_resultado_recepcion INTEGER;
--              IN  p_observaciones TEXT
--              OUT p_resultado VARCHAR(30) ('Recibido' o 'Rechazado y descartado')
-- Tablas:      recepciones, recepcion_detalle, traslados, custodias_recurso, recursos, reservas,
--              asignaciones, solicitudes, descarte_recursos, almacenamientos_recurso
-- Reglas:      Permiso 'Confirmar recepciones'. Solo traslados En tránsito (regla 8.15). Recibe el
--              hospital destino o logística. Si se rechaza, el motivo es obligatorio. Si llegó
--              caducado se rechaza aunque digan conforme (caso 12.5). Rechazado: reserva y asignación
--              se cancelan, la solicitud vuelve a En proceso y el recurso queda Descartado
--              (casos 12.6, 12.7).
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_registrar_recepcion(77, 6, 1, NULL, NULL);
-- Esperado:    'Recibido' (recurso Reservado ya en el hospital). Repetirlo: ERROR "El traslado no
--              está En tránsito".
-- Flask:       /asignaciones/recepcion
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_recepcion(
    IN p_id_traslado INTEGER,
    IN p_id_personal INTEGER,
    IN p_id_resultado_recepcion INTEGER,
    IN p_observaciones TEXT,
    OUT p_resultado VARCHAR(30)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_traslado SMALLINT;
    v_destino INTEGER;
    v_inst_personal INTEGER;
    v_id_recepcion INTEGER;
    v_resultado SMALLINT;
    v_causa SMALLINT;
    rec RECORD;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Confirmar recepciones') THEN
        RAISE EXCEPTION 'No tienes permiso para confirmar recepciones';
    END IF;

    SELECT id_estado_traslado, id_institucion_destino INTO v_estado_traslado, v_destino
    FROM traslados WHERE id_traslado = p_id_traslado;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el traslado %', p_id_traslado;
    END IF;

    IF v_estado_traslado <> 2 THEN
        RAISE EXCEPTION 'El traslado no está En tránsito (ya fue entregado o no ha salido)';
    END IF;

    -- recibe el personal del hospital destino o logistica (confirma la entrega)
    SELECT id_institucion INTO v_inst_personal FROM personal WHERE id_personal = p_id_personal;
    IF v_inst_personal <> v_destino AND NOT fn_tiene_permiso(p_id_personal, 'Gestionar traslados') THEN
        RAISE EXCEPTION 'Solo el hospital destino o logística pueden confirmar la entrega';
    END IF;

    -- si se rechaza hay que decir por que
    IF p_id_resultado_recepcion <> 1 AND (p_observaciones IS NULL OR trim(p_observaciones) = '') THEN
        RAISE EXCEPTION 'Escribe el motivo del rechazo';
    END IF;

    INSERT INTO recepciones (id_traslado, id_personal, fecha_hora_recepcion, observaciones)
    VALUES (p_id_traslado, p_id_personal, now(), p_observaciones)
    RETURNING id_recepcion INTO v_id_recepcion;

    UPDATE traslados SET id_estado_traslado = 3, fecha_llegada = now()     -- Entregado
    WHERE id_traslado = p_id_traslado;

    p_resultado := 'Recibido';

    FOR rec IN
        SELECT a.id_recurso, a.id_asignacion, sd.id_solicitud
        FROM traslado_detalle td
        JOIN asignaciones a ON a.id_asignacion = td.id_asignacion
        JOIN matching m ON m.id_matching = a.id_matching
        JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
        WHERE td.id_traslado = p_id_traslado
    LOOP
        v_resultado := p_id_resultado_recepcion;

        -- llego caducado: aunque digan conforme, se rechaza (caso 12.5)
        IF fn_dias_restantes(rec.id_recurso) <= 0 THEN
            v_resultado := 3;
        END IF;

        INSERT INTO recepcion_detalle (id_recepcion, id_recurso, id_resultado_recepcion, observaciones)
        VALUES (v_id_recepcion, rec.id_recurso, v_resultado, p_observaciones);

        INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal,
                                       id_tipo_movimiento_custodia, fecha_hora, id_traslado)
        VALUES (rec.id_recurso, v_destino, p_id_personal, 3, now(), p_id_traslado);   -- Recepcion

        -- el recurso ya esta fisicamente en el hospital
        UPDATE recursos SET id_estado_recurso = 2, id_institucion = v_destino
        WHERE id_recurso = rec.id_recurso;

        IF v_resultado <> 1 THEN
            IF fn_dias_restantes(rec.id_recurso) <= 0 THEN
                v_causa := 4;     -- Caducidad
            ELSIF v_resultado = 2 THEN
                v_causa := 2;     -- Daño durante conservacion
            ELSE
                v_causa := 3;     -- Temperatura fuera de rango
            END IF;
            -- se cancela su reserva y su asignacion y se da de baja
            UPDATE reservas SET id_estado_reserva = 3, fecha_hora_fin = now()
            WHERE id_recurso = rec.id_recurso AND id_estado_reserva = 1;
            UPDATE asignaciones SET id_estado_asignacion = 3
            WHERE id_asignacion = rec.id_asignacion;
            -- la solicitud vuelve a buscar recurso si ya no tiene asignaciones activas
            IF NOT EXISTS (SELECT 1 FROM asignaciones a
                           JOIN matching m ON m.id_matching = a.id_matching
                           JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
                           WHERE sd.id_solicitud = rec.id_solicitud AND a.id_estado_asignacion = 1) THEN
                UPDATE solicitudes SET id_estado_solicitud = 1
                WHERE id_solicitud = rec.id_solicitud AND id_estado_solicitud = 2;
            END IF;
            INSERT INTO descarte_recursos (id_recurso, id_causa_descarte, fecha_hora, id_personal, observaciones)
            VALUES (rec.id_recurso, v_causa, now(), p_id_personal,
                    'Rechazado en la recepcion' || COALESCE(': ' || p_observaciones, ''));
            INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal,
                                           id_tipo_movimiento_custodia, fecha_hora, observaciones)
            VALUES (rec.id_recurso, v_destino, p_id_personal, 5, now(), 'Rechazado en la recepcion');
            UPDATE recursos SET id_estado_recurso = 5 WHERE id_recurso = rec.id_recurso;   -- Descartado
            UPDATE almacenamientos_recurso SET fecha_hora_fin = now()
            WHERE id_recurso = rec.id_recurso AND fecha_hora_fin IS NULL;
            p_resultado := 'Rechazado y descartado';
        END IF;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------
-- SP11. sp_registrar_transfusion
-- Propósito:   Registrar la transfusión de la unidad asignada al receptor de la solicitud.
-- Parámetros:  IN  p_id_asignacion INTEGER; IN p_id_personal INTEGER; IN p_id_resultado_transfusion INTEGER
--              OUT p_id_transfusion INTEGER
-- Tablas:      transfusiones, recursos, reservas, asignaciones, custodias_recurso,
--              almacenamientos_recurso, solicitudes
-- Reglas:      Permiso 'Registrar utilización de recursos'. Solo componentes sanguíneos. Asignación
--              Activa, recurso Reservado y ya recibido en el hospital, personal del hospital que pidió,
--              unidad vigente (regla 8.18). Recurso -> Utilizado, reserva -> Consumida,
--              asignación -> Completada; si se cubrieron todas las unidades, solicitud -> Atendida.
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_registrar_transfusion(109, 6, 1, NULL);
-- Esperado:    Id de la transfusión. Si la unidad no ha llegado: ERROR "falta el traslado y la recepción".
-- Flask:       /asignaciones/transfusion
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_transfusion(
    IN p_id_asignacion INTEGER,
    IN p_id_personal INTEGER,
    IN p_id_resultado_transfusion INTEGER,
    OUT p_id_transfusion INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_recurso INTEGER;
    v_estado_asig SMALLINT;
    v_estado_recurso SMALLINT;
    v_inst_recurso INTEGER;
    v_id_hospital INTEGER;
    v_id_receptor INTEGER;
    v_id_solicitud INTEGER;
    v_inst_personal INTEGER;
    v_faltan INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar utilización de recursos') THEN
        RAISE EXCEPTION 'No tienes permiso para registrar transfusiones';
    END IF;

    SELECT a.id_recurso, a.id_estado_asignacion, r.id_estado_recurso, r.id_institucion,
           s.id_hospital, s.id_receptor, s.id_solicitud
    INTO v_id_recurso, v_estado_asig, v_estado_recurso, v_inst_recurso,
         v_id_hospital, v_id_receptor, v_id_solicitud
    FROM asignaciones a
    JOIN recursos r ON r.id_recurso = a.id_recurso
    JOIN matching m ON m.id_matching = a.id_matching
    JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
    JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
    WHERE a.id_asignacion = p_id_asignacion;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La asignación % no existe', p_id_asignacion;
    END IF;

    IF v_estado_asig <> 1 THEN
        RAISE EXCEPTION 'La asignación no está Activa';
    END IF;

    IF (SELECT id_tipo_recurso FROM recursos WHERE id_recurso = v_id_recurso) <> 1 THEN
        RAISE EXCEPTION 'Solo se transfunden componentes sanguíneos';
    END IF;

    IF v_estado_recurso <> 2 THEN
        RAISE EXCEPTION 'El recurso no está listo para usarse (debe estar Reservado y recibido)';
    END IF;

    IF v_inst_recurso <> v_id_hospital THEN
        RAISE EXCEPTION 'El recurso todavía no llega al hospital, falta el traslado y la recepción';
    END IF;

    SELECT id_institucion INTO v_inst_personal FROM personal WHERE id_personal = p_id_personal;
    IF v_inst_personal <> v_id_hospital THEN
        RAISE EXCEPTION 'Solo el personal del hospital que pidió la sangre puede registrar la transfusión';
    END IF;

    IF fn_dias_restantes(v_id_recurso) <= 0 THEN
        RAISE EXCEPTION 'El recurso ya caducó, no se puede transfundir';
    END IF;

    INSERT INTO transfusiones (id_recurso, id_receptor, id_institucion, id_personal,
                               fecha_hora, id_resultado_transfusion)
    VALUES (v_id_recurso, v_id_receptor, v_id_hospital, p_id_personal, now(), p_id_resultado_transfusion)
    RETURNING id_transfusion INTO p_id_transfusion;

    UPDATE recursos SET id_estado_recurso = 4 WHERE id_recurso = v_id_recurso;        -- Utilizado
    UPDATE reservas SET id_estado_reserva = 4, fecha_hora_fin = now()                -- Consumida
    WHERE id_asignacion = p_id_asignacion AND id_estado_reserva = 1;
    UPDATE asignaciones SET id_estado_asignacion = 2 WHERE id_asignacion = p_id_asignacion; -- Completada

    INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal,
                                   id_tipo_movimiento_custodia, fecha_hora)
    VALUES (v_id_recurso, v_id_hospital, p_id_personal, 4, now());                    -- Entrega para uso

    UPDATE almacenamientos_recurso SET fecha_hora_fin = now()
    WHERE id_recurso = v_id_recurso AND fecha_hora_fin IS NULL;

    -- ¿quedan lineas sin cubrir?
    SELECT count(*) INTO v_faltan
    FROM solicitudes_detalle sd
    WHERE sd.id_solicitud = v_id_solicitud
      AND sd.cantidad > (SELECT count(*) FROM asignaciones a
                         JOIN matching m ON m.id_matching = a.id_matching
                         WHERE m.id_solicitud_detalle = sd.id_solicitud_detalle
                           AND a.id_estado_asignacion = 2);

    IF v_faltan = 0 THEN
        UPDATE solicitudes SET id_estado_solicitud = 3 WHERE id_solicitud = v_id_solicitud;  -- Atendida
    END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- SP12. sp_descartar_recurso
-- Propósito:   Dar de baja (descartar) un recurso que ya no se puede usar.
-- Parámetros:  IN  p_id_recurso INTEGER; IN p_id_causa INTEGER; IN p_id_personal INTEGER;
--              IN  p_observaciones TEXT (motivo, obligatorio)
--              (no tiene parámetros OUT)
-- Tablas:      descarte_recursos, custodias_recurso, recursos, almacenamientos_recurso, reservas,
--              asignaciones, solicitudes
-- Reglas:      Permiso 'Registrar descartes'. Motivo obligatorio. No se descarta algo Utilizado, ya
--              Descartado o En traslado. Si estaba Reservado se cancelan su reserva y asignación y la
--              solicitud vuelve a En proceso si ya no le queda ninguna asignación activa.
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_descartar_recurso(150, 4, 3, 'Unidad caducada');
-- Esperado:    Sin resultado (CALL); el recurso queda Descartado. Repetirlo: ERROR "ya estaba Descartado".
-- Flask:       /inventario/descartar
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_descartar_recurso(
    IN p_id_recurso INTEGER,
    IN p_id_causa INTEGER,
    IN p_id_personal INTEGER,
    IN p_observaciones TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado SMALLINT;
    v_id_institucion INTEGER;
    v_id_asignacion INTEGER;
    v_id_solicitud INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar descartes') THEN
        RAISE EXCEPTION 'No tienes permiso para descartar recursos';
    END IF;

    IF p_observaciones IS NULL OR trim(p_observaciones) = '' THEN
        RAISE EXCEPTION 'Escribe el motivo del descarte';
    END IF;

    SELECT id_estado_recurso, id_institucion INTO v_estado, v_id_institucion
    FROM recursos WHERE id_recurso = p_id_recurso;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El recurso % no existe', p_id_recurso;
    END IF;

    IF v_estado = 4 THEN
        RAISE EXCEPTION 'El recurso ya fue Utilizado, no se puede descartar';
    ELSIF v_estado = 5 THEN
        RAISE EXCEPTION 'El recurso ya estaba Descartado';
    ELSIF v_estado = 3 THEN
        RAISE EXCEPTION 'El recurso está En traslado, primero se debe registrar la recepción';
    END IF;

    -- si estaba reservado, cancelar reserva y asignacion
    SELECT a.id_asignacion, sd.id_solicitud INTO v_id_asignacion, v_id_solicitud
    FROM asignaciones a
    JOIN matching m ON m.id_matching = a.id_matching
    JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
    WHERE a.id_recurso = p_id_recurso AND a.id_estado_asignacion = 1;

    IF v_id_asignacion IS NOT NULL THEN
        UPDATE reservas SET id_estado_reserva = 3, fecha_hora_fin = now()
        WHERE id_asignacion = v_id_asignacion AND id_estado_reserva = 1;

        UPDATE asignaciones SET id_estado_asignacion = 3 WHERE id_asignacion = v_id_asignacion;

        -- la solicitud vuelve a buscar recurso si ya no tiene asignaciones activas
        IF NOT EXISTS (SELECT 1 FROM asignaciones a
                       JOIN matching m ON m.id_matching = a.id_matching
                       JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
                       WHERE sd.id_solicitud = v_id_solicitud AND a.id_estado_asignacion = 1) THEN
            UPDATE solicitudes SET id_estado_solicitud = 1
            WHERE id_solicitud = v_id_solicitud AND id_estado_solicitud = 2;
        END IF;
    END IF;

    INSERT INTO descarte_recursos (id_recurso, id_causa_descarte, fecha_hora, id_personal, observaciones)
    VALUES (p_id_recurso, p_id_causa, now(), p_id_personal, p_observaciones);

    INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal,
                                   id_tipo_movimiento_custodia, fecha_hora, observaciones)
    VALUES (p_id_recurso, v_id_institucion, p_id_personal, 5, now(), p_observaciones);  -- Baja por descarte

    UPDATE recursos SET id_estado_recurso = 5 WHERE id_recurso = p_id_recurso;    -- Descartado

    -- cerrar el almacenamiento vigente
    UPDATE almacenamientos_recurso SET fecha_hora_fin = now()
    WHERE id_recurso = p_id_recurso AND fecha_hora_fin IS NULL;
END;
$$;


-- ---------------------------------------------------------------------
-- SP13. sp_registrar_organo
-- Propósito:   Registrar un órgano extraído de un donante (operación de extracción + recurso + órgano).
-- Parámetros:  IN  p_id_personal INTEGER; IN p_id_donante INTEGER; IN p_id_tipo_organo INTEGER;
--              IN  p_id_lado INTEGER (solo riñón/pulmón); IN p_peso_gramos NUMERIC; IN p_tamano_cm NUMERIC;
--              IN  p_horas_viabilidad INTEGER
--              OUT p_id_recurso INTEGER
-- Tablas:      operaciones, operaciones_personal, recursos, organos, almacenamientos_recurso,
--              custodias_recurso
-- Reglas:      Permiso 'Registrar evaluaciones de órganos'. La institución debe hacer Procuración de
--              órganos (regla 7.2). Donante existente y no Inactivo. Riñón y pulmón llevan lado; los
--              demás no. Horas de viabilidad > 0 (regla 8.3). Peso y tamaño > 0. Folio automático.
--              El órgano queda En evaluación (no entra al matching hasta ser Viable).
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_registrar_organo(6, 1, 1, 1, 150, 11.5, 24, NULL);
-- Esperado:    Id del recurso. Riñón sin lado: ERROR "Para riñón o pulmón indica el lado".
-- Flask:       /organos/registrar
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_organo(
    IN p_id_personal INTEGER,
    IN p_id_donante INTEGER,
    IN p_id_tipo_organo INTEGER,
    IN p_id_lado INTEGER,
    IN p_peso_gramos NUMERIC,
    IN p_tamano_cm NUMERIC,
    IN p_horas_viabilidad INTEGER,
    OUT p_id_recurso INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_institucion INTEGER;
    v_id_persona INTEGER;
    v_estado_donante SMALLINT;
    v_tipo_sangre SMALLINT;
    v_id_operacion INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar evaluaciones de órganos') THEN
        RAISE EXCEPTION 'No tienes permiso para registrar órganos';
    END IF;

    SELECT id_institucion INTO v_id_institucion FROM personal WHERE id_personal = p_id_personal;

    IF NOT fn_institucion_ofrece(v_id_institucion, 4) THEN
        RAISE EXCEPTION 'Tu institución no hace procuración de órganos';
    END IF;

    SELECT id_persona, id_estado_donante, id_tipo_sanguineo
    INTO v_id_persona, v_estado_donante, v_tipo_sangre
    FROM donantes WHERE id_donante = p_id_donante;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El donante % no existe', p_id_donante;
    END IF;

    IF v_estado_donante = 2 THEN
        RAISE EXCEPTION 'El donante está Inactivo';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cat_organos WHERE id_tipo_organo = p_id_tipo_organo) THEN
        RAISE EXCEPTION 'El tipo de órgano % no existe', p_id_tipo_organo;
    END IF;

    -- rinon (1) y pulmon (4) son pares: hay que decir cual
    IF p_id_tipo_organo IN (1, 4) AND p_id_lado IS NULL THEN
        RAISE EXCEPTION 'Para riñón o pulmón indica el lado';
    END IF;

    IF p_id_tipo_organo NOT IN (1, 4) AND p_id_lado IS NOT NULL THEN
        RAISE EXCEPTION 'Ese órgano no lleva lado';
    END IF;

    IF p_horas_viabilidad IS NULL OR p_horas_viabilidad <= 0 THEN
        RAISE EXCEPTION 'Las horas de viabilidad deben ser mayores que cero';
    END IF;

    IF (p_peso_gramos IS NOT NULL AND p_peso_gramos <= 0) OR (p_tamano_cm IS NOT NULL AND p_tamano_cm <= 0) THEN
        RAISE EXCEPTION 'El peso y el tamaño deben ser mayores que cero';
    END IF;

    -- operacion de extraccion
    INSERT INTO operaciones (id_persona, id_institucion, id_personal, id_tipo_operacion, fecha_hora, id_estado_operacion)
    VALUES (v_id_persona, v_id_institucion, p_id_personal, 1, now(), 2)       -- Extraccion, Completada
    RETURNING id_operacion INTO v_id_operacion;

    INSERT INTO operaciones_personal (id_operacion, id_personal) VALUES (v_id_operacion, p_id_personal);

    INSERT INTO recursos (id_tipo_recurso, id_institucion, id_tipo_sanguineo, id_estado_recurso,
                          fecha_hora_origen, folio, observaciones)
    VALUES (2, v_id_institucion, v_tipo_sangre, 1, now(),
            'ORG-' || lpad(v_id_operacion::TEXT, 5, '0') || '-' || p_id_tipo_organo || COALESCE('-' || p_id_lado, ''),
            'Extraído en la operación ' || v_id_operacion)
    RETURNING id_recurso INTO p_id_recurso;

    INSERT INTO organos (id_recurso, id_extraccion, id_tipo_organo, fecha_hora_caducidad, id_viabilidad_organo,
                         id_lado_organo, peso_gramos, tamano_cm)
    VALUES (p_id_recurso, v_id_operacion, p_id_tipo_organo, now() + (p_horas_viabilidad || ' hours')::INTERVAL,
            2, p_id_lado, p_peso_gramos, p_tamano_cm);                        -- 2 = En evaluacion

    INSERT INTO almacenamientos_recurso (id_recurso, id_tipo_almacenamiento, fecha_hora_inicio,
                                         temperatura_registrada, id_personal)
    VALUES (p_id_recurso, 3, now(), 4, p_id_personal);                         -- Conservacion fria

    INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal, id_tipo_movimiento_custodia, fecha_hora)
    VALUES (p_id_recurso, v_id_institucion, p_id_personal, 1, now());          -- Ingreso a almacenamiento
END;
$$;


-- ---------------------------------------------------------------------
-- SP14. sp_registrar_solicitud_organo
-- Propósito:   Una institución con servicio de Trasplante pide un órgano para un receptor.
-- Parámetros:  IN  p_id_receptor INTEGER; IN p_id_personal INTEGER; IN p_id_urgencia INTEGER;
--              IN  p_id_tipo_organo INTEGER; IN p_tamano_min, p_tamano_max NUMERIC (opcionales);
--              IN  p_horas_limite INTEGER; IN p_motivo VARCHAR(255)
--              OUT p_id_solicitud INTEGER; OUT p_candidatos INTEGER
-- Tablas:      solicitudes, solicitudes_detalle, requisitos_organo, matching (vía SP6)
-- Reglas:      Permiso 'Registrar solicitudes'. Institución Activa con Trasplante (reglas 7.2, 7.7).
--              Receptor registrado y no Inactivo. Rango de tamaño válido (mínimo <= máximo).
--              Motivo obligatorio, horas límite > 0. Busca candidatos al momento.
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_registrar_solicitud_organo(2, 17, 1, 1, 10, 13, 12, 'Insuficiencia renal', NULL, NULL);
-- Esperado:    (id de la solicitud, candidatos). Desde Materno Infantil (sin Trasplante): ERROR.
-- Flask:       /solicitudes/nueva (formulario de órgano)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_solicitud_organo(
    IN p_id_receptor INTEGER,
    IN p_id_personal INTEGER,
    IN p_id_urgencia INTEGER,
    IN p_id_tipo_organo INTEGER,
    IN p_tamano_min NUMERIC,
    IN p_tamano_max NUMERIC,
    IN p_horas_limite INTEGER,
    IN p_motivo VARCHAR(255),
    OUT p_id_solicitud INTEGER,
    OUT p_candidatos INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_institucion INTEGER;
    v_estado_receptor SMALLINT;
    v_id_detalle INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar solicitudes') THEN
        RAISE EXCEPTION 'No tienes permiso para registrar solicitudes';
    END IF;

    SELECT id_institucion INTO v_id_institucion FROM personal WHERE id_personal = p_id_personal;

    IF NOT fn_institucion_ofrece(v_id_institucion, 3) THEN
        RAISE EXCEPTION 'Solo una institución activa con servicio de trasplante puede pedir órganos';
    END IF;

    SELECT id_estado_receptor INTO v_estado_receptor FROM receptores WHERE id_receptor = p_id_receptor;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El receptor % no está registrado', p_id_receptor;
    END IF;

    IF v_estado_receptor = 2 THEN
        RAISE EXCEPTION 'El receptor está Inactivo';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cat_organos WHERE id_tipo_organo = p_id_tipo_organo) THEN
        RAISE EXCEPTION 'El tipo de órgano % no existe', p_id_tipo_organo;
    END IF;

    IF (p_tamano_min IS NOT NULL AND p_tamano_min <= 0)
       OR (p_tamano_min IS NOT NULL AND p_tamano_max IS NOT NULL AND p_tamano_min > p_tamano_max) THEN
        RAISE EXCEPTION 'El rango de tamaño no es válido';
    END IF;

    IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
        RAISE EXCEPTION 'El motivo es obligatorio';
    END IF;

    IF p_horas_limite IS NULL OR p_horas_limite <= 0 THEN
        RAISE EXCEPTION 'Las horas límite deben ser mayores que cero';
    END IF;

    INSERT INTO solicitudes (id_hospital, id_receptor, id_personal, id_urgencia, id_estado_solicitud,
                             fecha_hora_solicitud, fecha_limite, motivo)
    VALUES (v_id_institucion, p_id_receptor, p_id_personal, p_id_urgencia, 1,
            now(), now() + (p_horas_limite || ' hours')::INTERVAL, trim(p_motivo))
    RETURNING id_solicitud INTO p_id_solicitud;

    INSERT INTO solicitudes_detalle (id_solicitud, id_tipo_recurso, cantidad)
    VALUES (p_id_solicitud, 2, 1)                                 -- un organo
    RETURNING id_solicitud_detalle INTO v_id_detalle;

    INSERT INTO requisitos_organo (id_solicitud_detalle, id_tipo_organo, tamano_minimo_cm, tamano_maximo_cm)
    VALUES (v_id_detalle, p_id_tipo_organo, p_tamano_min, p_tamano_max);

    CALL sp_generar_matching(v_id_detalle, p_candidatos);
END;
$$;


-- ---------------------------------------------------------------------
-- SP15. sp_registrar_trasplante
-- Propósito:   Registrar el trasplante del órgano asignado al receptor de la solicitud.
-- Parámetros:  IN  p_id_asignacion INTEGER; IN p_id_personal INTEGER
--              OUT p_id_operacion INTEGER
-- Tablas:      operaciones, operaciones_personal, recursos, reservas, asignaciones,
--              custodias_recurso, almacenamientos_recurso, solicitudes
-- Reglas:      Permiso 'Registrar utilización de recursos'. Solo órganos. Asignación Activa, órgano
--              recibido en la institución que lo pidió, personal de esa institución, dentro de su
--              tiempo de viabilidad (regla 8.18). Órgano -> Utilizado, reserva -> Consumida,
--              asignación -> Completada, solicitud -> Atendida.
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_registrar_trasplante(110, 18, NULL);
-- Esperado:    Id de la operación de trasplante. Con una unidad de sangre: ERROR "registra una transfusión".
-- Flask:       /asignaciones/trasplante
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_trasplante(
    IN p_id_asignacion INTEGER,
    IN p_id_personal INTEGER,
    OUT p_id_operacion INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_recurso INTEGER;
    v_tipo_recurso SMALLINT;
    v_estado_asig SMALLINT;
    v_estado_recurso SMALLINT;
    v_inst_recurso INTEGER;
    v_id_hospital INTEGER;
    v_id_persona_receptor INTEGER;
    v_id_solicitud INTEGER;
    v_inst_personal INTEGER;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Registrar utilización de recursos') THEN
        RAISE EXCEPTION 'No tienes permiso para registrar trasplantes';
    END IF;

    SELECT a.id_recurso, r.id_tipo_recurso, a.id_estado_asignacion, r.id_estado_recurso, r.id_institucion,
           s.id_hospital, rc.id_persona, s.id_solicitud
    INTO v_id_recurso, v_tipo_recurso, v_estado_asig, v_estado_recurso, v_inst_recurso,
         v_id_hospital, v_id_persona_receptor, v_id_solicitud
    FROM asignaciones a
    JOIN recursos r ON r.id_recurso = a.id_recurso
    JOIN matching m ON m.id_matching = a.id_matching
    JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
    JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
    JOIN receptores rc ON rc.id_receptor = s.id_receptor
    WHERE a.id_asignacion = p_id_asignacion;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La asignación % no existe', p_id_asignacion;
    END IF;

    IF v_tipo_recurso <> 2 THEN
        RAISE EXCEPTION 'Es una unidad de sangre, registra una transfusión';
    END IF;

    IF v_estado_asig <> 1 THEN
        RAISE EXCEPTION 'La asignación no está Activa';
    END IF;

    IF v_estado_recurso <> 2 OR v_inst_recurso <> v_id_hospital THEN
        RAISE EXCEPTION 'El órgano todavía no llega a la institución, falta el traslado y la recepción';
    END IF;

    SELECT id_institucion INTO v_inst_personal FROM personal WHERE id_personal = p_id_personal;
    IF v_inst_personal <> v_id_hospital THEN
        RAISE EXCEPTION 'Solo el personal de la institución que pidió el órgano puede registrar el trasplante';
    END IF;

    IF fn_dias_restantes(v_id_recurso) <= 0 THEN
        RAISE EXCEPTION 'El órgano ya perdió su tiempo de viabilidad';
    END IF;

    INSERT INTO operaciones (id_persona, id_institucion, id_personal, id_tipo_operacion, fecha_hora, id_estado_operacion)
    VALUES (v_id_persona_receptor, v_id_hospital, p_id_personal, 3, now(), 2)   -- Trasplante, Completada
    RETURNING id_operacion INTO p_id_operacion;

    INSERT INTO operaciones_personal (id_operacion, id_personal) VALUES (p_id_operacion, p_id_personal);

    UPDATE recursos SET id_estado_recurso = 4 WHERE id_recurso = v_id_recurso;          -- Utilizado
    UPDATE reservas SET id_estado_reserva = 4, fecha_hora_fin = now()                  -- Consumida
    WHERE id_asignacion = p_id_asignacion AND id_estado_reserva = 1;
    UPDATE asignaciones SET id_estado_asignacion = 2 WHERE id_asignacion = p_id_asignacion; -- Completada

    INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal, id_tipo_movimiento_custodia, fecha_hora)
    VALUES (v_id_recurso, v_id_hospital, p_id_personal, 4, now());                      -- Entrega para uso

    UPDATE almacenamientos_recurso SET fecha_hora_fin = now()
    WHERE id_recurso = v_id_recurso AND fecha_hora_fin IS NULL;

    UPDATE solicitudes SET id_estado_solicitud = 3 WHERE id_solicitud = v_id_solicitud;  -- Atendida
END;
$$;


-- ---------------------------------------------------------------------
-- SP16. sp_cancelar_solicitud
-- Propósito:   Cancelar una solicitud (baja lógica: no se borra, queda Cancelada con su motivo).
-- Parámetros:  IN  p_id_solicitud INTEGER; IN p_id_personal INTEGER; IN p_motivo TEXT
--              OUT p_liberados INTEGER (recursos que regresaron a Disponible)
-- Tablas:      solicitudes, asignaciones, reservas, recursos, matching, descarte_recursos,
--              custodias_recurso, almacenamientos_recurso
-- Reglas:      Permiso 'Gestionar reservas'. Motivo obligatorio. Solo solicitudes En proceso/Aprobada
--              y de la propia institución (salvo coordinador regional). No se cancela si algún recurso
--              va En traslado (caso 12.4). Reservas -> Liberada, asignaciones -> Cancelada; el recurso
--              vuelve a Disponible si sigue vigente o se descarta si caducó (caso 12.9). Reglas 7.13,
--              8.17, 8.20.
-- Excepciones: RAISE EXCEPTION por cada regla.
-- Invocación:  CALL sp_cancelar_solicitud(70, 6, 'El paciente fue dado de alta', NULL);
-- Esperado:    Número de recursos liberados. Repetirlo: ERROR "La solicitud ya está Atendida o Cancelada".
-- Flask:       /solicitudes/<id>/cancelar
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_cancelar_solicitud(
    IN p_id_solicitud INTEGER,
    IN p_id_personal INTEGER,
    IN p_motivo TEXT,
    OUT p_liberados INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado SMALLINT;
    v_id_hospital INTEGER;
    v_inst_personal INTEGER;
    rec RECORD;
BEGIN
    IF NOT fn_tiene_permiso(p_id_personal, 'Gestionar reservas') THEN
        RAISE EXCEPTION 'No tienes permiso para cancelar solicitudes';
    END IF;

    IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
        RAISE EXCEPTION 'Escribe el motivo de la cancelación';
    END IF;

    SELECT id_estado_solicitud, id_hospital INTO v_estado, v_id_hospital
    FROM solicitudes WHERE id_solicitud = p_id_solicitud;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La solicitud % no existe', p_id_solicitud;
    END IF;

    IF v_estado IN (3, 4) THEN
        RAISE EXCEPTION 'La solicitud ya está Atendida o Cancelada';
    END IF;

    -- solo la institucion que pidio, salvo el coordinador regional (ve toda la red)
    SELECT id_institucion INTO v_inst_personal FROM personal WHERE id_personal = p_id_personal;
    IF v_inst_personal <> v_id_hospital AND NOT fn_tiene_permiso(p_id_personal, 'Consultar reportes regionales') THEN
        RAISE EXCEPTION 'Solo puedes cancelar solicitudes de tu institución';
    END IF;

    -- caso 12.4: algo ya viene en camino
    IF EXISTS (SELECT 1 FROM asignaciones a
               JOIN recursos r ON r.id_recurso = a.id_recurso
               JOIN matching m ON m.id_matching = a.id_matching
               JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
               WHERE sd.id_solicitud = p_id_solicitud
                 AND a.id_estado_asignacion = 1
                 AND r.id_estado_recurso = 3) THEN
        RAISE EXCEPTION 'No se puede cancelar: hay un recurso En traslado, primero registren la recepción';
    END IF;

    p_liberados := 0;

    FOR rec IN
        SELECT a.id_asignacion, a.id_recurso, r.id_estado_recurso, r.id_institucion
        FROM asignaciones a
        JOIN recursos r ON r.id_recurso = a.id_recurso
        JOIN matching m ON m.id_matching = a.id_matching
        JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
        WHERE sd.id_solicitud = p_id_solicitud
          AND a.id_estado_asignacion = 1
    LOOP
        UPDATE reservas SET id_estado_reserva = 2, fecha_hora_fin = now()     -- Liberada
        WHERE id_asignacion = rec.id_asignacion AND id_estado_reserva = 1;

        UPDATE asignaciones SET id_estado_asignacion = 3                        -- Cancelada
        WHERE id_asignacion = rec.id_asignacion;

        -- caso 12.9: solo regresa a Disponible si seguia Reservado y vigente
        IF rec.id_estado_recurso = 2 THEN
            IF fn_dias_restantes(rec.id_recurso) > 0 THEN
                UPDATE recursos SET id_estado_recurso = 1 WHERE id_recurso = rec.id_recurso;
                p_liberados := p_liberados + 1;
            ELSE
                -- caduco mientras estaba reservado: se da de baja
                INSERT INTO descarte_recursos (id_recurso, id_causa_descarte, fecha_hora, id_personal, observaciones)
                VALUES (rec.id_recurso, 4, now(), p_id_personal, 'Caducó mientras estaba reservado');
                INSERT INTO custodias_recurso (id_recurso, id_institucion, id_personal,
                                               id_tipo_movimiento_custodia, fecha_hora, observaciones)
                VALUES (rec.id_recurso, rec.id_institucion, p_id_personal, 5, now(), 'Caducó mientras estaba reservado');
                UPDATE recursos SET id_estado_recurso = 5 WHERE id_recurso = rec.id_recurso;   -- Descartado
                UPDATE almacenamientos_recurso SET fecha_hora_fin = now()
                WHERE id_recurso = rec.id_recurso AND fecha_hora_fin IS NULL;
            END IF;
        END IF;
    END LOOP;

    UPDATE solicitudes
    SET id_estado_solicitud = 4,
        observaciones = COALESCE(observaciones || ' | ', '') || 'Cancelada: ' || trim(p_motivo)
    WHERE id_solicitud = p_id_solicitud;

    -- los candidatos de esta solicitud ya no estan vigentes
    UPDATE matching SET disponible = FALSE
    WHERE id_solicitud_detalle IN (SELECT id_solicitud_detalle FROM solicitudes_detalle
                                   WHERE id_solicitud = p_id_solicitud);
END;
$$;
