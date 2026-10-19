-- =====================================================================
-- 05_vistas.sql
-- VISTAS - Banco de sangre y órganos (las 5 vistas mínimas)
-- Ejecutar después de 04:
--   sudo -u postgres psql < 05_vistas.sql
--
-- Dónde se usan en Flask (app.py):
--   vista_hospitales_solicitudes_activas -> Inicio y Reportes
--   vista_inventario_sangre              -> Inventario
--   vista_matching                       -> Detalle de una solicitud (historial de matching)
--   vista_traslados                      -> Traslados
--   vista_inventario_proximo_a_caducar   -> Inicio (alertas)
-- =====================================================================
\set ON_ERROR_STOP on
\c banco_sangre_organos

-- ---------------------------------------------------------------------
-- 17.1 Hospitales con sus solicitudes activas, tipo de sangre,
--      fecha de solicitud y cantidad
--      (activas = 'En proceso' o 'Aprobada')
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_hospitales_solicitudes_activas AS
SELECT
    h.id_institucion                 AS id_hospital,
    h.nombre                         AS hospital,
    s.id_solicitud,
    es.nombre                        AS estado_solicitud,
    u.nombre                         AS urgencia,
    ts.nombre                        AS tipo_sangre,
    s.fecha_hora_solicitud           AS fecha_solicitud,
    s.fecha_limite,
    SUM(sd.cantidad)                 AS cantidad,
    s.motivo
FROM solicitudes s
JOIN instituciones h            ON h.id_institucion = s.id_hospital
JOIN cat_estados_solicitud es   ON es.id_estado_solicitud = s.id_estado_solicitud
JOIN cat_urgencias u            ON u.id_urgencia = s.id_urgencia
JOIN receptores r               ON r.id_receptor = s.id_receptor
JOIN cat_tipos_sanguineo ts     ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
JOIN solicitudes_detalle sd     ON sd.id_solicitud = s.id_solicitud
WHERE es.nombre IN ('En proceso', 'Aprobada')
GROUP BY h.id_institucion, h.nombre, s.id_solicitud, es.nombre, u.nombre, u.peso,
         ts.nombre, s.fecha_hora_solicitud, s.fecha_limite, s.motivo
ORDER BY u.peso DESC, s.fecha_limite;

-- ---------------------------------------------------------------------
-- 17.2 Inventario de sangre con fecha de caducidad, fecha de extracción,
--      banco de sangre, tipo de sangre y cantidad (ml de la donación)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_inventario_sangre AS
SELECT
    rc.id_recurso,
    rc.folio,
    b.id_institucion                 AS id_banco_sangre,
    b.nombre                         AS banco_sangre,
    ts.nombre                        AS tipo_sangre,
    cs.nombre                        AS componente,
    er.nombre                        AS estado_recurso,
    rc.fecha_hora_origen             AS fecha_extraccion,
    u.fecha_hora_caducidad           AS fecha_caducidad,
    d.volumen_ml::NUMERIC(8,2)       AS cantidad
FROM recursos rc
JOIN unidades_componentes_sanguineos u ON u.id_recurso = rc.id_recurso
JOIN donaciones d               ON d.id_donacion = u.id_donacion
JOIN instituciones b            ON b.id_institucion = rc.id_institucion
JOIN cat_tipos_sanguineo ts     ON ts.id_tipo_sanguineo = rc.id_tipo_sanguineo
JOIN cat_componentes_sangre cs  ON cs.id_componente = u.id_componente
JOIN cat_estados_recurso er     ON er.id_estado_recurso = rc.id_estado_recurso
ORDER BY b.nombre, u.fecha_hora_caducidad;

-- ---------------------------------------------------------------------
-- 17.3 Matching con datos de compatibilidad, unidad asignada,
--      hospital, banco de sangre y estado de la asignación
--      (estado NULL = candidato evaluado que no fue asignado)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_matching AS
SELECT
    m.id_matching,
    s.id_solicitud,
    h.nombre                         AS hospital,
    b.nombre                         AS banco_sangre,
    rc.folio                         AS unidad_asignada,
    c.nombre                         AS resultado_compatibilidad,
    m.disponible,
    m.explicacion,
    m.fecha_hora_calculo,
    ea.nombre                        AS estado,
    a.fecha_hora_asignacion
FROM matching m
JOIN solicitudes_detalle sd     ON sd.id_solicitud_detalle = m.id_solicitud_detalle
JOIN solicitudes s              ON s.id_solicitud = sd.id_solicitud
JOIN instituciones h            ON h.id_institucion = s.id_hospital
JOIN recursos rc                ON rc.id_recurso = m.id_recurso
JOIN instituciones b            ON b.id_institucion = rc.id_institucion
JOIN cat_resultados_compatibilidad c ON c.id_resultado_compatibilidad = m.id_resultado_compatibilidad
LEFT JOIN asignaciones a        ON a.id_matching = m.id_matching
LEFT JOIN cat_estados_asignacion ea ON ea.id_estado_asignacion = a.id_estado_asignacion
ORDER BY m.id_matching;

-- ---------------------------------------------------------------------
-- 17.4 Traslados con su estado, lugar de salida y lugar de llegada
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_traslados AS
SELECT
    t.id_traslado,
    o.nombre                         AS lugar_salida,
    d.nombre                         AS lugar_llegada,
    et.nombre                        AS estado,
    t.fecha_salida,
    t.fecha_estimada_llegada,
    t.fecha_llegada,
    mt.nombre                        AS medio_transporte,
    t.id_institucion_origen,
    t.id_institucion_destino
FROM traslados t
JOIN instituciones o            ON o.id_institucion = t.id_institucion_origen
JOIN instituciones d            ON d.id_institucion = t.id_institucion_destino
JOIN cat_estados_traslado et    ON et.id_estado_traslado = t.id_estado_traslado
JOIN cat_medios_transporte mt   ON mt.id_medio_transporte = t.id_medio_transporte
ORDER BY t.fecha_salida DESC;

-- ---------------------------------------------------------------------
-- 17.5 Unidades próximas a caducar (disponibles o reservadas, que vencen
--      en los próximos 7 días) con su institución, tipo de sangre,
--      fecha de caducidad y cantidad
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_inventario_proximo_a_caducar AS
SELECT
    rc.id_recurso,
    rc.folio,
    i.id_institucion,
    i.nombre                         AS institucion,
    ts.nombre                        AS tipo_sangre,
    cs.nombre                        AS componente,
    u.fecha_hora_caducidad           AS fecha_caducidad,
    d.volumen_ml::NUMERIC(8,2)       AS cantidad,
    (u.fecha_hora_caducidad::DATE - CURRENT_DATE) AS dias_restantes
FROM recursos rc
JOIN unidades_componentes_sanguineos u ON u.id_recurso = rc.id_recurso
JOIN donaciones d               ON d.id_donacion = u.id_donacion
JOIN instituciones i            ON i.id_institucion = rc.id_institucion
JOIN cat_tipos_sanguineo ts     ON ts.id_tipo_sanguineo = rc.id_tipo_sanguineo
JOIN cat_componentes_sangre cs  ON cs.id_componente = u.id_componente
JOIN cat_estados_recurso er     ON er.id_estado_recurso = rc.id_estado_recurso
WHERE er.nombre IN ('Disponible', 'Reservado')
  AND u.fecha_hora_caducidad >= now()
  AND u.fecha_hora_caducidad <  now() + INTERVAL '7 days'
ORDER BY u.fecha_hora_caducidad;
