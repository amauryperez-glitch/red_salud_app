-- =====================================================================
-- 03_funciones.sql
-- Funciones (CREATE FUNCTION) de apoyo para los procedimientos y vistas.
-- OJO: son FUNCIONES (se usan con SELECT o dentro de expresiones), NO
-- cuentan como procedimientos almacenados (esos están en 04, con CALL).
--
-- Ejecutar después de 02:
--   sudo -u postgres psql < 03_funciones.sql
-- =====================================================================
\set ON_ERROR_STOP on
\c banco_sangre_organos

-- ---------------------------------------------------------------------
-- F0. fn_verificar_password
-- Compara la contraseña escrita con el hash bcrypt guardado en
-- usuarios.password_hash (las contraseñas NUNCA se guardan en texto).
-- pgcrypto genera hashes "$2a$" y los datos de prueba vienen en "$2b$";
-- ambos son bcrypt con el mismo cálculo, por eso se normaliza el prefijo.
-- Ejemplo: SELECT fn_verificar_password('Demo2026!', password_hash) FROM usuarios WHERE id_usuario = 1;
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_verificar_password(p_password VARCHAR, p_hash VARCHAR)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_hash TEXT;
BEGIN
    IF p_password IS NULL OR p_hash IS NULL OR p_hash !~ '^\$2[abxy]\$' THEN
        RETURN FALSE;
    END IF;
    v_hash := '$2a$' || substr(p_hash, 5);
    RETURN crypt(p_password, v_hash) = v_hash;
END;
$$;


-- ---------------------------------------------------------------------
-- F1. fn_calcular_edad
-- Recibe fecha de nacimiento y regresa la edad en años cumplidos
-- Ejemplo: SELECT fn_calcular_edad('2000-05-10');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_calcular_edad(p_fecha_nacimiento DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN EXTRACT(YEAR FROM age(CURRENT_DATE, p_fecha_nacimiento));
END;
$$;


-- ---------------------------------------------------------------------
-- F2. fn_compatible_sangre
-- Regresa TRUE si la sangre del donador sirve para el receptor (ABO/Rh)
--   Eritrocitos: el donador no puede traer un antigeno (A o B) que el
--                receptor no tenga. Receptor Rh- solo recibe Rh-.
--   Plasma:      al reves, el receptor no puede tener un antigeno que el
--                donador no tenga (AB es el plasma universal). Rh no importa.
--   Plaquetas:   se usa la regla del plasma + la regla Rh (simplificacion
--                del equipo, se debe revisar con la guia del CNTS).
--   Organos (p_id_componente = 0): solo ABO, igual que eritrocitos pero
--                sin revisar Rh.
-- Ejemplo: SELECT fn_compatible_sangre('O-', 'A+', 1);  -> true
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_compatible_sangre(
    p_tipo_donador VARCHAR,
    p_tipo_receptor VARCHAR,
    p_id_componente INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_abo_d VARCHAR(2);
    v_abo_r VARCHAR(2);
    v_rh_d CHAR(1);
    v_rh_r CHAR(1);
    v_d_tiene_a BOOLEAN;
    v_d_tiene_b BOOLEAN;
    v_r_tiene_a BOOLEAN;
    v_r_tiene_b BOOLEAN;
    v_abo_ok BOOLEAN;
    v_rh_ok BOOLEAN;
BEGIN
    -- separar el grupo (O, A, B, AB) del Rh (+ o -)
    v_abo_d := replace(replace(p_tipo_donador, '+', ''), '-', '');
    v_abo_r := replace(replace(p_tipo_receptor, '+', ''), '-', '');
    v_rh_d := right(p_tipo_donador, 1);
    v_rh_r := right(p_tipo_receptor, 1);

    v_d_tiene_a := position('A' in v_abo_d) > 0;
    v_d_tiene_b := position('B' in v_abo_d) > 0;
    v_r_tiene_a := position('A' in v_abo_r) > 0;
    v_r_tiene_b := position('B' in v_abo_r) > 0;

    -- Rh: un receptor negativo solo recibe negativo
    v_rh_ok := (v_rh_r = '+' OR v_rh_d = '-');

    IF p_id_componente = 0 THEN
        -- Organo: solo grupo ABO
        v_abo_ok := (NOT v_d_tiene_a OR v_r_tiene_a) AND (NOT v_d_tiene_b OR v_r_tiene_b);
        RETURN v_abo_ok;
    ELSIF p_id_componente = 1 THEN
        -- Concentrado de eritrocitos
        v_abo_ok := (NOT v_d_tiene_a OR v_r_tiene_a) AND (NOT v_d_tiene_b OR v_r_tiene_b);
        RETURN v_abo_ok AND v_rh_ok;
    ELSIF p_id_componente = 2 THEN
        -- Plasma fresco congelado
        v_abo_ok := (NOT v_r_tiene_a OR v_d_tiene_a) AND (NOT v_r_tiene_b OR v_d_tiene_b);
        RETURN v_abo_ok;
    ELSE
        -- Concentrado de plaquetas
        v_abo_ok := (NOT v_r_tiene_a OR v_d_tiene_a) AND (NOT v_r_tiene_b OR v_d_tiene_b);
        RETURN v_abo_ok AND v_rh_ok;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- F3. fn_distancia_km
-- Formula del documento (seccion 10):
-- distancia = R * ACOS(SEN(lat1)*SEN(lat2) + COS(lat1)*COS(lat2)*COS(lon2-lon1))
-- Se usa LEAST/GREATEST para que el ACOS no truene por redondeo
-- Ejemplo: SELECT fn_distancia_km(25.699, -100.367, 25.6876, -100.3498);
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_distancia_km(
    p_lat1 NUMERIC, p_lon1 NUMERIC,
    p_lat2 NUMERIC, p_lon2 NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_valor DOUBLE PRECISION;
BEGIN
    v_valor := sin(radians(p_lat1)) * sin(radians(p_lat2))
             + cos(radians(p_lat1)) * cos(radians(p_lat2)) * cos(radians(p_lon2 - p_lon1));
    v_valor := LEAST(1, GREATEST(-1, v_valor));
    RETURN round((6371 * acos(v_valor))::NUMERIC, 2);
END;
$$;


-- ---------------------------------------------------------------------
-- F4. fn_dias_restantes
-- Dias que le quedan a un recurso (unidad de sangre u organo).
-- Si es <= 0 ya no esta vigente.  NULL si el recurso no existe.
-- Ejemplo: SELECT fn_dias_restantes(150);
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_dias_restantes(p_id_recurso INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_caducidad TIMESTAMPTZ;
BEGIN
    SELECT fecha_hora_caducidad INTO v_caducidad
    FROM unidades_componentes_sanguineos
    WHERE id_recurso = p_id_recurso;

    IF v_caducidad IS NULL THEN
        SELECT fecha_hora_caducidad INTO v_caducidad
        FROM organos
        WHERE id_recurso = p_id_recurso;
    END IF;

    IF v_caducidad IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN round((EXTRACT(EPOCH FROM (v_caducidad - now())) / 86400)::NUMERIC, 2);
END;
$$;


-- ---------------------------------------------------------------------
-- F5. fn_tiene_permiso
-- Revisa si el personal tiene un permiso por medio de
-- usuarios -> usuario_rol -> rol_permiso -> cat_permisos   (regla 8.14)
-- Ejemplo: SELECT fn_tiene_permiso(2, 'Aprobar asignaciones');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_tiene_permiso(p_id_personal INTEGER, p_permiso VARCHAR)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_total INTEGER;
BEGIN
    SELECT count(*) INTO v_total
    FROM usuarios u
    JOIN usuario_rol ur ON ur.id_usuario = u.id_usuario
    JOIN rol_permiso rp ON rp.id_rol = ur.id_rol
    JOIN cat_permisos cp ON cp.id_permiso = rp.id_permiso
    WHERE u.id_personal = p_id_personal
      AND u.id_estado_usuario = 1          -- usuario Activo
      AND cp.nombre = p_permiso;

    RETURN v_total > 0;
END;
$$;


-- ---------------------------------------------------------------------
-- F6. fn_institucion_ofrece
-- TRUE si la institucion esta Activa y tiene el servicio  (regla 7.2)
-- Servicios: 1 Donacion de sangre, 2 Transfusion, 3 Trasplante,
--            4 Procuracion de organos, 5 Laboratorio clinico
-- Ejemplo: SELECT fn_institucion_ofrece(1, 1);
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_institucion_ofrece(p_id_institucion INTEGER, p_id_servicio INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_total INTEGER;
BEGIN
    SELECT count(*) INTO v_total
    FROM instituciones i
    JOIN institucion_servicio s ON s.id_institucion = i.id_institucion
    WHERE i.id_institucion = p_id_institucion
      AND i.id_estado_institucion = 1      -- Activa
      AND s.id_servicio = p_id_servicio;

    RETURN v_total > 0;
END;
$$;


-- ---------------------------------------------------------------------
-- F7. fn_puntaje_matching
-- Puntaje del documento (seccion 10), solo sirve para ORDENAR (regla 7.11).
-- Sirve para sangre y para organos (el tipo del receptor sale de la solicitud):
--   P_compatibilidad: 50 si el tipo es exacto, 30 si solo es compatible
--   P_urgencia:       el peso de cat_urgencias (Urgente 30, Prioritaria 20, Normal 10)
--   P_cercania:       hasta 20, se le quita 1 punto por cada 10 km
--   P_caducidad:      hasta 15, entre menos dias le queden mas puntos (FEFO)
--   P_disponibilidad: 20 si el recurso esta Disponible
-- Ejemplo: SELECT fn_puntaje_matching(234);
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_puntaje_matching(p_id_matching INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo_recurso VARCHAR(5);
    v_tipo_receptor VARCHAR(5);
    v_peso SMALLINT;
    v_estado SMALLINT;
    v_lat1 NUMERIC; v_lon1 NUMERIC;
    v_lat2 NUMERIC; v_lon2 NUMERIC;
    v_id_recurso INTEGER;
    v_km NUMERIC;
    v_dias NUMERIC;
    v_p_compat INTEGER;
    v_p_cerca INTEGER;
    v_p_cad INTEGER;
    v_p_disp INTEGER;
BEGIN
    SELECT m.id_recurso, ts_rec.nombre, ts_req.nombre, u.peso, r.id_estado_recurso,
           d1.latitud, d1.longitud, d2.latitud, d2.longitud
    INTO v_id_recurso, v_tipo_recurso, v_tipo_receptor, v_peso, v_estado,
         v_lat1, v_lon1, v_lat2, v_lon2
    FROM matching m
    JOIN recursos r ON r.id_recurso = m.id_recurso
    JOIN cat_tipos_sanguineo ts_rec ON ts_rec.id_tipo_sanguineo = r.id_tipo_sanguineo
    JOIN solicitudes_detalle sd ON sd.id_solicitud_detalle = m.id_solicitud_detalle
    JOIN solicitudes s ON s.id_solicitud = sd.id_solicitud
    JOIN receptores rc ON rc.id_receptor = s.id_receptor
    JOIN cat_tipos_sanguineo ts_req ON ts_req.id_tipo_sanguineo = rc.id_tipo_sanguineo
    JOIN cat_urgencias u ON u.id_urgencia = s.id_urgencia
    JOIN instituciones i1 ON i1.id_institucion = r.id_institucion
    JOIN direcciones_institucion d1 ON d1.id_direccion = i1.id_direccion
    JOIN instituciones i2 ON i2.id_institucion = s.id_hospital
    JOIN direcciones_institucion d2 ON d2.id_direccion = i2.id_direccion
    WHERE m.id_matching = p_id_matching;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    -- compatibilidad
    IF v_tipo_recurso = v_tipo_receptor THEN
        v_p_compat := 50;
    ELSE
        v_p_compat := 30;
    END IF;

    -- cercania
    v_km := fn_distancia_km(v_lat1, v_lon1, v_lat2, v_lon2);
    v_p_cerca := GREATEST(0, 20 - floor(v_km / 10))::INTEGER;

    -- caducidad
    v_dias := fn_dias_restantes(v_id_recurso);
    IF v_dias <= 3 THEN
        v_p_cad := 15;
    ELSIF v_dias <= 7 THEN
        v_p_cad := 10;
    ELSIF v_dias <= 15 THEN
        v_p_cad := 5;
    ELSE
        v_p_cad := 0;
    END IF;

    -- disponibilidad
    IF v_estado = 1 THEN
        v_p_disp := 20;
    ELSE
        v_p_disp := 0;
    END IF;

    RETURN v_p_compat + v_peso + v_p_cerca + v_p_cad + v_p_disp;
END;
$$;
