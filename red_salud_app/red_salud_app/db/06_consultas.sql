-- =====================================================================
-- 06_consultas.sql
-- CONSULTAS CON JOIN Y CONSULTAS COMPLEMENTARIAS
-- Banco de sangre y órganos
-- Solo consultan (no modifican datos). Ejecutar después de 05 y guardar
-- la salida como evidencia:
--   sudo -u postgres psql < 06_consultas.sql > 06_resultado_consultas.txt
--
-- Aplicación en el sistema (app.py):
--   5 CROSS JOIN (unidades vs. mínimo)      -> Inicio, alerta de inventario bajo mínimo
--   2 LEFT JOIN (personal con/sin usuario)   -> Personal (columna Usuario)
--   11 CTE (aprovechamiento por banco)        -> Reportes
--   12 Ventana RANK / SUM OVER (hospitales)   -> Reportes
-- =====================================================================
\c banco_sangre_organos
SET TIME ZONE 'America/Monterrey';

-- ---------------------------------------------------------------------
-- 1. INNER JOIN
-- Pregunta: ¿Qué transfusiones se han realizado, a qué receptor, en qué
--           hospital y con qué tipo de sangre?
-- Solo aparecen recursos que SÍ tienen una transfusión registrada.
-- ---------------------------------------------------------------------
SELECT t.id_transfusion,
       t.fecha_hora::date               AS fecha,
       h.nombre                         AS hospital,
       p.nombres || ' ' || p.apellidos  AS receptor,
       ts.nombre                        AS tipo_receptor,
       r.folio                          AS unidad,
       rt.nombre                        AS resultado
FROM transfusiones t
INNER JOIN recursos r                   ON r.id_recurso = t.id_recurso
INNER JOIN receptores rc                ON rc.id_receptor = t.id_receptor
INNER JOIN personas p                   ON p.id_persona = rc.id_persona
INNER JOIN cat_tipos_sanguineo ts       ON ts.id_tipo_sanguineo = rc.id_tipo_sanguineo
INNER JOIN instituciones h              ON h.id_institucion = t.id_institucion
INNER JOIN cat_resultados_transfusion rt ON rt.id_resultado_transfusion = t.id_resultado_transfusion
ORDER BY t.fecha_hora DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- 2. LEFT JOIN
-- Pregunta: ¿Qué miembros del personal tienen cuenta de usuario y cuáles
--           no? (el administrador debe dar de alta a los que faltan)
-- Se conservan TODOS los registros de personal; los que no tienen
-- usuario aparecen con NULL en las columnas de usuarios.
-- ---------------------------------------------------------------------
SELECT pe.id_personal,
       p.nombres || ' ' || p.apellidos  AS empleado,
       c.nombre                         AS cargo,
       i.nombre                         AS institucion,
       u.usuario_login,
       eu.nombre                        AS estado_usuario
FROM personal pe
JOIN personas p                         ON p.id_persona = pe.id_persona
JOIN cat_cargos c                       ON c.id_cargo = pe.id_cargo
JOIN instituciones i                    ON i.id_institucion = pe.id_institucion
LEFT JOIN usuarios u                    ON u.id_personal = pe.id_personal
LEFT JOIN cat_estados_usuario eu        ON eu.id_estado_usuario = u.id_estado_usuario
ORDER BY (u.id_usuario IS NULL) DESC, pe.id_personal;

-- Comparación: con INNER JOIN se pierden los empleados sin usuario
SELECT 'LEFT JOIN'  AS tipo, count(*) FROM personal pe LEFT  JOIN usuarios u ON u.id_personal = pe.id_personal
UNION ALL
SELECT 'INNER JOIN' AS tipo, count(*) FROM personal pe INNER JOIN usuarios u ON u.id_personal = pe.id_personal;

-- ---------------------------------------------------------------------
-- 3. RIGHT JOIN
-- Pregunta: ¿Cuántas solicitudes ha registrado cada institución,
--           incluyendo las que no han registrado ninguna?
-- La tabla derecha (instituciones) se conserva completa: los bancos de
-- sangre y el hospital suspendido aparecen con 0 solicitudes.
-- ---------------------------------------------------------------------
SELECT i.id_institucion,
       i.nombre                         AS institucion,
       ti.nombre                        AS tipo,
       count(s.id_solicitud)            AS total_solicitudes
FROM solicitudes s
RIGHT JOIN instituciones i              ON i.id_institucion = s.id_hospital
JOIN cat_tipos_instituciones ti         ON ti.id_tipo_institucion = i.id_tipo_institucion
GROUP BY i.id_institucion, i.nombre, ti.nombre
ORDER BY total_solicitudes DESC, i.id_institucion;

-- ---------------------------------------------------------------------
-- 4. FULL OUTER JOIN
-- Pregunta: ¿Qué personas del sistema son personal, cuáles son donantes
--           y cuáles son ambas cosas?
-- Coincidentes: personal que también dona sangre.
-- No coincidentes: personal que no dona y donantes que no son personal.
-- ---------------------------------------------------------------------
SELECT COALESCE(pe.id_persona, d.id_persona)      AS id_persona,
       p.nombres || ' ' || p.apellidos            AS persona,
       CASE
           WHEN pe.id_personal IS NOT NULL AND d.id_donante IS NOT NULL THEN 'Personal y donante'
           WHEN pe.id_personal IS NOT NULL THEN 'Solo personal'
           ELSE 'Solo donante'
       END                                        AS clasificacion,
       pe.id_personal,
       d.id_donante
FROM personal pe
FULL OUTER JOIN donantes d              ON d.id_persona = pe.id_persona
JOIN personas p                         ON p.id_persona = COALESCE(pe.id_persona, d.id_persona)
ORDER BY clasificacion, id_persona;

-- Resumen del FULL OUTER JOIN
SELECT CASE
           WHEN pe.id_personal IS NOT NULL AND d.id_donante IS NOT NULL THEN 'Personal y donante'
           WHEN pe.id_personal IS NOT NULL THEN 'Solo personal'
           ELSE 'Solo donante'
       END AS clasificacion,
       count(*) AS personas
FROM personal pe
FULL OUTER JOIN donantes d ON d.id_persona = pe.id_persona
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- 5. CROSS JOIN
-- Pregunta: ¿Cuántas unidades disponibles tiene cada banco de sangre de
--           cada componente, incluyendo las combinaciones en cero?
-- Justificación: el CROSS JOIN genera TODAS las combinaciones
-- banco × componente para que un faltante (0 unidades) también aparezca
-- y pueda compararse contra el umbral mínimo de inventario.
-- ---------------------------------------------------------------------
SELECT b.nombre                         AS banco_sangre,
       c.nombre                         AS componente,
       count(r.id_recurso)              AS disponibles,
       ui.minimo,
       CASE WHEN count(r.id_recurso) < ui.minimo THEN 'BAJO MÍNIMO' ELSE 'OK' END AS alerta
FROM instituciones b
CROSS JOIN cat_componentes_sangre c
LEFT JOIN unidades_componentes_sanguineos u ON u.id_componente = c.id_componente
LEFT JOIN recursos r                    ON r.id_recurso = u.id_recurso
                                       AND r.id_institucion = b.id_institucion
                                       AND r.id_estado_recurso = (SELECT id_estado_recurso FROM cat_estados_recurso WHERE nombre = 'Disponible')
LEFT JOIN umbrales_inventario ui        ON ui.id_institucion = b.id_institucion
                                       AND ui.id_componente = c.id_componente
                                       AND ui.activo
WHERE b.id_tipo_institucion = (SELECT id_tipo_institucion FROM cat_tipos_instituciones WHERE nombre = 'Banco de sangre')
GROUP BY b.nombre, c.nombre, ui.minimo
ORDER BY b.nombre, c.nombre;

-- ---------------------------------------------------------------------
-- 6. SELF JOIN
-- Pregunta: ¿Se respeta el intervalo mínimo de 56 días entre dos
--           donaciones de sangre consecutivas del mismo donante?
-- La tabla donaciones se une consigo misma: d1 = donación anterior,
-- d2 = siguiente donación del mismo donante.
-- ---------------------------------------------------------------------
SELECT p.nombres || ' ' || p.apellidos  AS donante,
       d1.id_donacion                   AS donacion_anterior,
       d1.fecha_hora_inicio::date       AS fecha_anterior,
       d2.id_donacion                   AS donacion_siguiente,
       d2.fecha_hora_inicio::date       AS fecha_siguiente,
       d2.fecha_hora_inicio::date - d1.fecha_hora_inicio::date AS dias_entre,
       CASE WHEN d2.fecha_hora_inicio - d1.fecha_hora_inicio >= INTERVAL '56 days'
            THEN 'Cumple' ELSE 'NO cumple' END AS intervalo
FROM donaciones d1
JOIN donaciones d2                      ON d2.id_donante = d1.id_donante
                                       AND d2.fecha_hora_inicio > d1.fecha_hora_inicio
                                       AND d2.id_tipo_donacion = d1.id_tipo_donacion
JOIN donantes dn                        ON dn.id_donante = d1.id_donante
JOIN personas p                         ON p.id_persona = dn.id_persona
WHERE d1.id_tipo_donacion = (SELECT id_tipo_donacion FROM cat_tipos_donacion WHERE nombre = 'Sangre')
  AND NOT EXISTS (                       -- que no haya otra donación entre d1 y d2
        SELECT 1 FROM donaciones dx
        WHERE dx.id_donante = d1.id_donante
          AND dx.fecha_hora_inicio > d1.fecha_hora_inicio
          AND dx.fecha_hora_inicio < d2.fecha_hora_inicio)
ORDER BY dias_entre;

-- ---------------------------------------------------------------------
-- 7. JOIN DE 3 O MÁS TABLAS
-- Pregunta: Trazabilidad completa de una unidad transfundida: ¿quién la
--           donó, en qué banco, cómo se trasladó y a quién se transfundió?
-- Involucra donantes, donaciones, recursos, asignaciones, traslados,
-- receptores, hospitales y personal (más de 10 tablas).
-- ---------------------------------------------------------------------
SELECT r.folio                                   AS unidad,
       cs.nombre                                 AS componente,
       pd.nombres || ' ' || pd.apellidos         AS donante,
       tsd.nombre                                AS tipo_donante,
       b.nombre                                  AS banco_origen,
       d.fecha_hora_inicio::date                 AS fecha_donacion,
       s.id_solicitud,
       tr.fecha_salida                           AS salida_traslado,
       tr.fecha_llegada                          AS llegada_traslado,
       pr.nombres || ' ' || pr.apellidos         AS receptor,
       tsr.nombre                                AS tipo_receptor,
       h.nombre                                  AS hospital,
       t.fecha_hora                              AS fecha_transfusion,
       pm.nombres || ' ' || pm.apellidos         AS personal_que_transfundio
FROM transfusiones t
JOIN recursos r                         ON r.id_recurso = t.id_recurso
JOIN unidades_componentes_sanguineos u  ON u.id_recurso = r.id_recurso
JOIN cat_componentes_sangre cs          ON cs.id_componente = u.id_componente
JOIN donaciones d                       ON d.id_donacion = u.id_donacion
JOIN instituciones b                    ON b.id_institucion = d.id_institucion
JOIN donantes dn                        ON dn.id_donante = d.id_donante
JOIN personas pd                        ON pd.id_persona = dn.id_persona
JOIN cat_tipos_sanguineo tsd            ON tsd.id_tipo_sanguineo = dn.id_tipo_sanguineo
JOIN asignaciones a                     ON a.id_recurso = r.id_recurso
                                       AND a.id_estado_asignacion = (SELECT id_estado_asignacion FROM cat_estados_asignacion WHERE nombre = 'Completada')
JOIN matching m                         ON m.id_matching = a.id_matching
JOIN solicitudes_detalle sd             ON sd.id_solicitud_detalle = m.id_solicitud_detalle
JOIN solicitudes s                      ON s.id_solicitud = sd.id_solicitud
JOIN traslado_detalle td                ON td.id_asignacion = a.id_asignacion
JOIN traslados tr                       ON tr.id_traslado = td.id_traslado
JOIN receptores rc                      ON rc.id_receptor = t.id_receptor
JOIN personas pr                        ON pr.id_persona = rc.id_persona
JOIN cat_tipos_sanguineo tsr            ON tsr.id_tipo_sanguineo = rc.id_tipo_sanguineo
JOIN instituciones h                    ON h.id_institucion = t.id_institucion
JOIN personal pe                        ON pe.id_personal = t.id_personal
JOIN personas pm                        ON pm.id_persona = pe.id_persona
ORDER BY t.fecha_hora DESC
LIMIT 5;

-- =====================================================================
-- CONSULTAS COMPLEMENTARIAS
-- =====================================================================

-- ---------------------------------------------------------------------
-- 8. Funciones de agregación (COUNT, SUM, AVG, MIN, MAX)
-- Pregunta: ¿Cuánta sangre ha captado cada banco y con qué volumen
--           promedio por donación?
-- ---------------------------------------------------------------------
SELECT b.nombre                                   AS banco_sangre,
       count(*)                                   AS donaciones_completadas,
       sum(d.volumen_ml)                          AS volumen_total_ml,
       round(avg(d.volumen_ml), 1)                AS volumen_promedio_ml,
       min(d.fecha_hora_inicio)::date             AS primera_donacion,
       max(d.fecha_hora_inicio)::date             AS ultima_donacion
FROM donaciones d
JOIN instituciones b            ON b.id_institucion = d.id_institucion
JOIN cat_estados_donacion ed    ON ed.id_estado_donacion = d.id_estado_donacion
JOIN cat_tipos_donacion td      ON td.id_tipo_donacion = d.id_tipo_donacion
WHERE ed.nombre = 'Completada' AND td.nombre = 'Sangre'
GROUP BY b.nombre
ORDER BY volumen_total_ml DESC;

-- ---------------------------------------------------------------------
-- 9. Subconsulta 1 (IN + subconsulta correlacionada)
-- Pregunta: ¿Qué unidades disponibles podrían cubrir una solicitud
--           activa de sangre del mismo tipo sanguíneo y componente?
--           (apoya al coordinador a decidir qué unidad reservar)
-- ---------------------------------------------------------------------
SELECT v.id_recurso, v.folio, v.banco_sangre, v.tipo_sangre, v.componente, v.fecha_caducidad
FROM vista_inventario_sangre v
WHERE v.estado_recurso = 'Disponible'
  AND (v.tipo_sangre, v.componente) IN (
        SELECT ts.nombre, cs.nombre
        FROM solicitudes s
        JOIN cat_estados_solicitud es   ON es.id_estado_solicitud = s.id_estado_solicitud
        JOIN solicitudes_detalle sd     ON sd.id_solicitud = s.id_solicitud
        JOIN requisitos_sangre rs       ON rs.id_solicitud_detalle = sd.id_solicitud_detalle
        JOIN cat_tipos_sanguineo ts     ON ts.id_tipo_sanguineo = rs.id_tipo_sanguineo
        JOIN cat_componentes_sangre cs  ON cs.id_componente = rs.id_componente
        WHERE es.nombre IN ('En proceso', 'Aprobada'))
ORDER BY v.fecha_caducidad;

-- ---------------------------------------------------------------------
-- 10. Subconsulta 2 (subconsulta escalar en WHERE y en SELECT)
-- Pregunta: ¿Qué hospitales tardan más que el promedio general desde que
--           registran la solicitud hasta que se transfunde la unidad?
-- ---------------------------------------------------------------------
SELECT h.nombre                                              AS hospital,
       count(*)                                              AS transfusiones,
       round(avg(extract(epoch FROM t.fecha_hora - s.fecha_hora_solicitud) / 3600)::numeric, 2) AS horas_promedio,
       (SELECT round(avg(extract(epoch FROM t2.fecha_hora - s2.fecha_hora_solicitud) / 3600)::numeric, 2)
          FROM transfusiones t2
          JOIN asignaciones a2          ON a2.id_recurso = t2.id_recurso AND a2.id_estado_asignacion = 2
          JOIN matching m2              ON m2.id_matching = a2.id_matching
          JOIN solicitudes_detalle sd2  ON sd2.id_solicitud_detalle = m2.id_solicitud_detalle
          JOIN solicitudes s2           ON s2.id_solicitud = sd2.id_solicitud) AS horas_promedio_general
FROM transfusiones t
JOIN asignaciones a             ON a.id_recurso = t.id_recurso AND a.id_estado_asignacion = 2
JOIN matching m                 ON m.id_matching = a.id_matching
JOIN solicitudes_detalle sd     ON sd.id_solicitud_detalle = m.id_solicitud_detalle
JOIN solicitudes s              ON s.id_solicitud = sd.id_solicitud
JOIN instituciones h            ON h.id_institucion = t.id_institucion
GROUP BY h.nombre
HAVING avg(t.fecha_hora - s.fecha_hora_solicitud) > (
        SELECT avg(t3.fecha_hora - s3.fecha_hora_solicitud)
        FROM transfusiones t3
        JOIN asignaciones a3          ON a3.id_recurso = t3.id_recurso AND a3.id_estado_asignacion = 2
        JOIN matching m3              ON m3.id_matching = a3.id_matching
        JOIN solicitudes_detalle sd3  ON sd3.id_solicitud_detalle = m3.id_solicitud_detalle
        JOIN solicitudes s3           ON s3.id_solicitud = sd3.id_solicitud)
ORDER BY horas_promedio DESC;

-- ---------------------------------------------------------------------
-- 11. Expresión de tabla común (CTE)
-- Pregunta: ¿Qué porcentaje de las unidades producidas por cada banco
--           se aprovechó (transfundió) y qué porcentaje se desperdició?
-- ---------------------------------------------------------------------
WITH unidades AS (
    SELECT r.id_institucion, r.id_recurso, er.nombre AS estado
    FROM recursos r
    JOIN unidades_componentes_sanguineos u ON u.id_recurso = r.id_recurso
    JOIN cat_estados_recurso er            ON er.id_estado_recurso = r.id_estado_recurso
),
resumen AS (
    SELECT id_institucion,
           count(*)                                         AS producidas,
           count(*) FILTER (WHERE estado = 'Utilizado')     AS utilizadas,
           count(*) FILTER (WHERE estado = 'Descartado')    AS descartadas,
           count(*) FILTER (WHERE estado IN ('Disponible', 'Reservado', 'En traslado')) AS en_inventario
    FROM unidades
    GROUP BY id_institucion
)
SELECT i.nombre                                             AS banco_sangre,
       r.producidas, r.utilizadas, r.descartadas, r.en_inventario,
       round(100.0 * r.utilizadas  / r.producidas, 1)       AS pct_aprovechado,
       round(100.0 * r.descartadas / r.producidas, 1)       AS pct_desperdicio
FROM resumen r
JOIN instituciones i ON i.id_institucion = r.id_institucion
ORDER BY pct_aprovechado DESC;

-- ---------------------------------------------------------------------
-- 12. Funciones de ventana (ROW_NUMBER, RANK, SUM OVER)
-- Pregunta: Para cada banco, tipo de sangre y componente, ¿en qué orden
--           deben despacharse las unidades disponibles según FEFO
--           (primero la que caduca antes)?
-- ---------------------------------------------------------------------
SELECT banco_sangre, tipo_sangre, componente, folio, fecha_caducidad,
       ROW_NUMBER() OVER (PARTITION BY id_banco_sangre, tipo_sangre, componente
                          ORDER BY fecha_caducidad)          AS orden_despacho_fefo,
       count(*)     OVER (PARTITION BY id_banco_sangre, tipo_sangre, componente) AS unidades_del_grupo
FROM vista_inventario_sangre
WHERE estado_recurso = 'Disponible'
ORDER BY banco_sangre, tipo_sangre, componente, orden_despacho_fefo;

-- Ventana 2: ranking de hospitales por consumo y acumulado (RANK y SUM OVER)
SELECT h.nombre                                         AS hospital,
       count(*)                                         AS unidades_transfundidas,
       RANK() OVER (ORDER BY count(*) DESC)             AS ranking,
       sum(count(*)) OVER (ORDER BY count(*) DESC, h.nombre) AS acumulado,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)    AS pct_del_total
FROM transfusiones t
JOIN instituciones h ON h.id_institucion = t.id_institucion
GROUP BY h.nombre
ORDER BY ranking;

-- ---------------------------------------------------------------------
-- 13. Inventario actual (sangre y órganos)
-- Pregunta: ¿Qué inventario vigente tiene cada institución, por tipo de
--           recurso, componente u órgano y tipo de sangre?
-- El inventario no se almacena (regla 7.15): se calcula a partir de
-- recursos + estado. LEFT JOIN a unidades y órganos para cubrir ambos
-- tipos de recurso; FILTER separa disponibles, reservadas y en traslado.
-- ---------------------------------------------------------------------
SELECT i.nombre                                   AS institucion,
       tr.nombre                                  AS tipo_recurso,
       COALESCE(cs.nombre, co.nombre)             AS componente_u_organo,
       ts.nombre                                  AS tipo_sangre,
       count(*) FILTER (WHERE er.nombre = 'Disponible')  AS disponibles,
       count(*) FILTER (WHERE er.nombre = 'Reservado')   AS reservadas,
       count(*) FILTER (WHERE er.nombre = 'En traslado') AS en_traslado,
       COALESCE(sum(d.volumen_ml) FILTER (WHERE er.nombre = 'Disponible'), 0) AS volumen_disponible_ml,
       min(COALESCE(u.fecha_hora_caducidad, o.fecha_hora_caducidad))         AS proxima_caducidad
FROM recursos r
JOIN instituciones i              ON i.id_institucion = r.id_institucion
JOIN cat_tipos_recurso tr         ON tr.id_tipo_recurso = r.id_tipo_recurso
JOIN cat_tipos_sanguineo ts       ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
JOIN cat_estados_recurso er       ON er.id_estado_recurso = r.id_estado_recurso
LEFT JOIN unidades_componentes_sanguineos u ON u.id_recurso = r.id_recurso
LEFT JOIN cat_componentes_sangre cs ON cs.id_componente = u.id_componente
LEFT JOIN donaciones d            ON d.id_donacion = u.id_donacion
LEFT JOIN organos o               ON o.id_recurso = r.id_recurso
LEFT JOIN cat_organos co          ON co.id_tipo_organo = o.id_tipo_organo
WHERE er.nombre IN ('Disponible', 'Reservado', 'En traslado')
  AND COALESCE(u.fecha_hora_caducidad, o.fecha_hora_caducidad) > now()
GROUP BY i.nombre, tr.nombre, COALESCE(cs.nombre, co.nombre), ts.nombre
ORDER BY i.nombre, tr.nombre, componente_u_organo, ts.nombre;
