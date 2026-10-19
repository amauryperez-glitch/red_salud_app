-- =====================================================================
-- 07_pruebas_procedimientos.sql
-- Pruebas de los 16 procedimientos (resultado esperado vs. obtenido).
-- OPCIONAL: AGREGA datos de prueba. Correr en una base recién cargada
-- (01 a 05) y guardar la salida como evidencia:
--   sudo -u postgres psql < 07_pruebas_procedimientos.sql > 07_resultado_pruebas.txt 2>&1
-- Después, para dejar la base limpia, vuelve a correr 01 a 05.
--
-- NO usa ON_ERROR_STOP a propósito: las pruebas marcadas
-- "ESPERADO: ERROR" deben fallar con el mensaje de la regla.
-- Personal que se usa (todos con contraseña Demo2026!):
--   2  tmedina   Coordinador regional (banco 1)
--   3  agomez    Laboratorio (banco 1)
--   4  gortiz    Logística (banco 1)
--   5  eesquivel Personal médico (banco 1)
--   6  rreyes    Coordinador hospitalario + médico (Hospital Universitario, id 2)
--   8  dgarza    Personal médico (Hospital Universitario, id 2)
--  11  vgonzalez Personal médico (Materno Infantil, sin Trasplante)
--  17  atamez    Coordinador hospitalario (Hospital Cumbres del Valle, id 6)
--  18  iibarra   Personal médico (Hospital Cumbres del Valle, id 6)
-- =====================================================================
\c banco_sangre_organos
\set ECHO none
\pset footer off

\echo '=================== SP1 sp_validar_login ==================='
\echo '--- 1.1 usuario y contraseña correctos (ESPERADO: 1 fila)'
BEGIN;
CALL sp_validar_login('tmedina', 'Demo2026!', NULL);
FETCH ALL FROM cursor_login;
COMMIT;
\echo '--- 1.2 contraseña incorrecta (ESPERADO: 0 filas)'
BEGIN;
CALL sp_validar_login('tmedina', 'otra', NULL);
FETCH ALL FROM cursor_login;
COMMIT;
\echo '--- 1.3 usuario Bloqueado lgomez con contraseña correcta (ESPERADO: 0 filas)'
BEGIN;
CALL sp_validar_login('lgomez', 'Demo2026!', NULL);
FETCH ALL FROM cursor_login;
COMMIT;

\echo '--- 1.4 usuario Inactivo crodriguez (ESPERADO: 0 filas)'
BEGIN;
CALL sp_validar_login('crodriguez', 'Demo2026!', NULL);
FETCH ALL FROM cursor_login;
COMMIT;
\echo '--- 1.5 la contraseña se guarda como hash bcrypt, no en texto (ESPERADO: empieza con $2)'
SELECT usuario_login, left(password_hash, 7) || '...' AS hash_guardado,
       fn_verificar_password('Demo2026!', password_hash) AS demo_ok,
       fn_verificar_password('demo2026!', password_hash) AS minusculas_ok
FROM usuarios WHERE usuario_login = 'tmedina';

\echo '=================== SP2 sp_registrar_donante ==================='
\echo '--- 2.1 donante nuevo O- (ESPERADO: regresa p_id_donante)'
CALL sp_registrar_donante('Mariana', 'Leal Garza', '1995-03-14', 1, 'mariana.leal@correo-demo.mx',
                          '8112345678', 3, 5, NULL) \gset
\echo 'id_donante nuevo =' :p_id_donante
\set donante1 :p_id_donante
\echo '--- 2.2 segundo donante (se usara para la prueba de laboratorio Reactivo)'
CALL sp_registrar_donante('Hector', 'Rios Salas', '1988-11-02', 2, 'hector.rios@correo-demo.mx',
                          NULL, 2, 5, NULL) \gset
\set donante2 :p_id_donante
\echo '--- 2.3 menor de edad (ESPERADO: ERROR)'
CALL sp_registrar_donante('Luis', 'Paz', '2012-01-01', 2, NULL, NULL, 1, 5, NULL);
\echo '--- 2.4 correo repetido (ESPERADO: ERROR)'
CALL sp_registrar_donante('Otra', 'Persona', '1990-01-01', 1, 'mariana.leal@correo-demo.mx', NULL, 1, 5, NULL);
\echo '--- 2.5 usuario sin permiso, laboratorio (ESPERADO: ERROR)'
CALL sp_registrar_donante('Sin', 'Permiso', '1990-01-01', 1, NULL, NULL, 1, 3, NULL);

\echo '=================== SP3 sp_registrar_donacion ==================='
\echo '--- 3.1 donante Diferido (la evaluacion No apto se hace desde Flask con UPDATE) (ESPERADO: ERROR)'
UPDATE donantes SET id_estado_donante = 3 WHERE id_donante = :donante1;
CALL sp_registrar_donacion(:donante1, 5, 450, 'CONS-P0001', NULL, NULL);
UPDATE donantes SET id_estado_donante = 1 WHERE id_donante = :donante1;
\echo '--- 3.2 donacion de 450 ml con su consentimiento (ESPERADO: id_donacion Pendiente y documento Vigente)'
CALL sp_registrar_donacion(:donante1, 5, 450, 'CONS-P0001', 'Donacion altruista', NULL) \gset
\set donacion1 :p_id_donacion
SELECT d.id_donacion, d.id_institucion, d.id_estado_donacion, doc.certificado_ref, ed.nombre AS estado_documento
FROM donaciones d JOIN documentos doc ON doc.id_donacion = d.id_donacion
JOIN cat_estados_documento ed ON ed.id_estado_documento = doc.id_estado_documento
WHERE d.id_donacion = :donacion1;
CALL sp_registrar_donacion(:donante2, 5, 450, 'CONS-P0002', NULL, NULL) \gset
\set donacion2 :p_id_donacion
\echo '--- 3.3 mismo donante otra vez el mismo dia (ESPERADO: ERROR 56 dias)'
CALL sp_registrar_donacion(:donante1, 5, 450, 'CONS-P0003', NULL, NULL);
\echo '--- 3.4 volumen fuera de rango (ESPERADO: ERROR)'
CALL sp_registrar_donacion(1, 5, 900, 'CONS-P0004', NULL, NULL);
\echo '--- 3.5 sin folio de consentimiento (ESPERADO: ERROR)'
CALL sp_registrar_donacion(1, 5, 450, '', NULL, NULL);

\echo '=================== SP4 sp_registrar_resultado_laboratorio ==================='
\echo '--- 4.1 todo No reactivo (ESPERADO: Aceptada)'
CALL sp_registrar_resultado_laboratorio(:donacion1, 3, 'No reactivo', 'No reactivo', 'No reactivo', 'No reactivo', NULL);
\echo '--- 4.2 Hepatitis C Reactivo (ESPERADO: Rechazada y donante Diferido)'
CALL sp_registrar_resultado_laboratorio(:donacion2, 3, 'No reactivo', 'No reactivo', 'Reactivo', 'No reactivo', NULL);
SELECT d.id_donante, ed.nombre AS estado_donante FROM donantes d
JOIN cat_estados_donante ed ON ed.id_estado_donante = d.id_estado_donante WHERE d.id_donante = :donante2;
\echo '--- 4.3 repetir resultado de la misma donacion (ESPERADO: ERROR)'
CALL sp_registrar_resultado_laboratorio(:donacion1, 3, 'No reactivo', 'No reactivo', 'No reactivo', 'No reactivo', NULL);
\echo '--- 4.4 personal sin permiso (ESPERADO: ERROR)'
CALL sp_registrar_resultado_laboratorio(:donacion1, 5, 'No reactivo', 'No reactivo', 'No reactivo', 'No reactivo', NULL);

\echo '=================== SP5 sp_fraccionar_donacion ==================='
\echo '--- 5.1 fraccionar donacion aceptada (ESPERADO: 3 unidades)'
CALL sp_fraccionar_donacion(:donacion1, 3, NULL);
SELECT r.folio, cs.nombre, to_char(u.fecha_hora_caducidad, 'DD/MM/YYYY') AS caduca, er.nombre AS estado
FROM unidades_componentes_sanguineos u
JOIN recursos r ON r.id_recurso = u.id_recurso
JOIN cat_componentes_sangre cs ON cs.id_componente = u.id_componente
JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
WHERE u.id_donacion = :donacion1 ORDER BY r.id_recurso;
\echo '--- 5.2 fraccionar donacion rechazada (ESPERADO: ERROR)'
CALL sp_fraccionar_donacion(:donacion2, 3, NULL);

\echo '=================== SP7 + SP6 sp_registrar_solicitud_sangre / sp_generar_matching ==================='
\echo '--- 7.1 Hospital Universitario pide 1 eritrocitos para receptor 4 (O+), Urgente (ESPERADO: solicitud + candidatos > 0)'
CALL sp_registrar_solicitud_sangre(4, 6, 1, 1, 1, 24, 'Anemia aguda por sangrado', NULL, NULL) \gset
\set sol1 :p_id_solicitud
\echo 'solicitud =' :p_id_solicitud ' candidatos =' :p_candidatos
SELECT id_solicitud_detalle AS det1 FROM solicitudes_detalle WHERE id_solicitud = :sol1 \gset
\echo '--- 6.1 candidatos ordenados por puntaje (ESPERADO: solo O+ y O-, nunca A/B/AB)'
SELECT r.folio, ts.nombre AS tipo, fn_puntaje_matching(m.id_matching) AS puntaje
FROM matching m JOIN recursos r ON r.id_recurso = m.id_recurso
JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
WHERE m.id_solicitud_detalle = :det1 AND m.disponible
ORDER BY 3 DESC, r.folio LIMIT 5;
SELECT DISTINCT ts.nombre AS tipos_encontrados FROM matching m JOIN recursos r ON r.id_recurso = m.id_recurso
JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
WHERE m.id_solicitud_detalle = :det1 AND m.disponible ORDER BY 1;
\echo '--- 6.2 regenerar el matching no duplica filas (ESPERADO: mismo total)'
CALL sp_generar_matching(:det1, NULL);
\echo '--- 6.3 linea que no existe (ESPERADO: ERROR)'
CALL sp_generar_matching(999999, NULL);
\echo '--- 7.2 banco de sangre intenta pedir sangre (ESPERADO: ERROR solo hospitales)'
CALL sp_registrar_solicitud_sangre(4, 5, 1, 1, 1, 24, 'Prueba', NULL, NULL);
\echo '--- 7.3 cantidad cero (ESPERADO: ERROR)'
CALL sp_registrar_solicitud_sangre(4, 6, 1, 1, 0, 24, 'Prueba', NULL, NULL);
\echo '--- 7.4 sin motivo (ESPERADO: ERROR)'
CALL sp_registrar_solicitud_sangre(4, 6, 1, 1, 1, 24, '', NULL, NULL);
\echo '--- 7.5 receptor 5 (AB+) pide plaquetas: no hay plaquetas AB (ESPERADO: 0 candidatos)'
CALL sp_registrar_solicitud_sangre(5, 6, 2, 3, 1, 48, 'Plaquetopenia', NULL, NULL);

\echo '=================== SP8 sp_asignar_recurso ==================='
SELECT m.id_matching AS mejor FROM matching m JOIN recursos r ON r.id_recurso = m.id_recurso
WHERE m.id_solicitud_detalle = :det1 AND m.disponible AND r.id_estado_recurso = 1
ORDER BY fn_puntaje_matching(m.id_matching) DESC, m.id_matching LIMIT 1 \gset
\echo '--- 8.1 usuario sin permiso rreyes (ESPERADO: ERROR)'
CALL sp_asignar_recurso(:mejor, 6, 'x', NULL);
\echo '--- 8.2 coordinador regional asigna el mejor candidato (ESPERADO: id_asignacion, recurso Reservado)'
CALL sp_asignar_recurso(:mejor, 2, 'Mejor puntaje y FEFO', NULL) \gset
\set asig1 :p_id_asignacion
SELECT a.id_asignacion, r.folio, er.nombre AS estado_recurso, es.nombre AS estado_solicitud
FROM asignaciones a JOIN recursos r ON r.id_recurso = a.id_recurso
JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
JOIN solicitudes s ON s.id_solicitud = :sol1
JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud
WHERE a.id_asignacion = :asig1;
\echo '--- 8.3 asignar sin motivo (ESPERADO: ERROR)'
CALL sp_asignar_recurso(:mejor, 2, '', NULL);
\echo '--- 8.4 asignar otra vez el mismo matching (ESPERADO: ERROR ya no Disponible)'
CALL sp_asignar_recurso(:mejor, 2, 'Segundo intento', NULL);

\echo '=================== SP11 (antes de tiempo) ==================='
\echo '--- 11.1 transfundir sin traslado (ESPERADO: ERROR todavia no llega)'
CALL sp_registrar_transfusion(:asig1, 6, 2, NULL);

\echo '=================== SP9 sp_programar_traslado ==================='
\echo '--- 9.1 personal medico sin permiso (ESPERADO: ERROR)'
CALL sp_programar_traslado(:asig1, 8, 1, 40, NULL);
\echo '--- 9.2 logistica envia en vehiculo refrigerado, 40 min (ESPERADO: id_traslado, recurso En traslado)'
CALL sp_programar_traslado(:asig1, 4, 1, 40, NULL) \gset
\set tras1 :p_id_traslado
SELECT t.id_traslado, io.nombre AS origen, idd.nombre AS destino, et.nombre AS estado
FROM traslados t JOIN instituciones io ON io.id_institucion = t.id_institucion_origen
JOIN instituciones idd ON idd.id_institucion = t.id_institucion_destino
JOIN cat_estados_traslado et ON et.id_estado_traslado = t.id_estado_traslado
WHERE t.id_traslado = :tras1;
\echo '--- 9.3 enviar otra vez (ESPERADO: ERROR ya no esta Reservado)'
CALL sp_programar_traslado(:asig1, 4, 1, 40, NULL);

\echo '=================== SP10 sp_registrar_recepcion ==================='
\echo '--- 10.1 coordinador de otro hospital intenta recibir (ESPERADO: ERROR)'
CALL sp_registrar_recepcion(:tras1, 17, 1, NULL, NULL);
\echo '--- 10.2 hospital recibe conforme (ESPERADO: Recibido)'
CALL sp_registrar_recepcion(:tras1, 6, 1, 'Llego a 4 grados', NULL);
\echo '--- 10.3 recibir otra vez el mismo traslado (ESPERADO: ERROR)'
CALL sp_registrar_recepcion(:tras1, 6, 1, NULL, NULL);

\echo '=================== SP11 sp_registrar_transfusion ==================='
\echo '--- 11.2 transfusion sin reaccion (ESPERADO: id_transfusion, solicitud Atendida)'
CALL sp_registrar_transfusion(:asig1, 6, 2, NULL);
SELECT s.id_solicitud, es.nombre AS estado FROM solicitudes s
JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud WHERE s.id_solicitud = :sol1;
\echo '--- trazabilidad del recurso (custodia)'
SELECT c.id_movimiento, tm.nombre AS movimiento, i.nombre AS institucion
FROM custodias_recurso c
JOIN cat_tipos_movimiento_custodia tm ON tm.id_tipo_movimiento_custodia = c.id_tipo_movimiento_custodia
JOIN instituciones i ON i.id_institucion = c.id_institucion
WHERE c.id_recurso = (SELECT id_recurso FROM asignaciones WHERE id_asignacion = :asig1)
ORDER BY c.id_movimiento;
\echo '--- 11.3 transfundir otra vez (ESPERADO: ERROR)'
CALL sp_registrar_transfusion(:asig1, 6, 2, NULL);

\echo '=================== SP10 recepcion rechazada ==================='
\echo '--- 10.4 nueva solicitud, se asigna, se envia y llega a 15 grados (ESPERADO: Rechazado y descartado, solicitud regresa a En proceso)'
CALL sp_registrar_solicitud_sangre(4, 6, 1, 1, 1, 24, 'Cirugia programada', NULL, NULL) \gset
\set sol3 :p_id_solicitud
SELECT m.id_matching AS m3 FROM matching m JOIN solicitudes_detalle sd USING (id_solicitud_detalle)
WHERE sd.id_solicitud = :sol3 AND m.disponible ORDER BY fn_puntaje_matching(m.id_matching) DESC, m.id_matching LIMIT 1 \gset
CALL sp_asignar_recurso(:m3, 2, 'Compatible y cercano', NULL) \gset
\set asig3 :p_id_asignacion
CALL sp_programar_traslado(:asig3, 4, 1, 30, NULL) \gset
\set tras3 :p_id_traslado
\echo '--- 10.5 rechazar sin motivo (ESPERADO: ERROR)'
CALL sp_registrar_recepcion(:tras3, 6, 3, '', NULL);
CALL sp_registrar_recepcion(:tras3, 6, 3, 'Llego a 15 grados', NULL);
SELECT r.folio, er.nombre AS estado_recurso, ea.nombre AS asignacion, es.nombre AS estado_solicitud
FROM asignaciones a JOIN recursos r ON r.id_recurso = a.id_recurso
JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
JOIN cat_estados_asignacion ea ON ea.id_estado_asignacion = a.id_estado_asignacion
JOIN solicitudes s ON s.id_solicitud = :sol3
JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud
WHERE a.id_asignacion = :asig3;

\echo '=================== SP12 sp_descartar_recurso ==================='
SELECT r.id_recurso AS rec_desc FROM recursos r JOIN unidades_componentes_sanguineos u USING (id_recurso)
WHERE u.id_donacion = :donacion1 AND u.id_componente = 2 \gset
\echo '--- 12.1 laboratorio descarta plasma por daño (ESPERADO: Descartado)'
CALL sp_descartar_recurso(:rec_desc, 2, 3, 'Bolsa rota');
SELECT r.folio, er.nombre FROM recursos r JOIN cat_estados_recurso er USING (id_estado_recurso) WHERE r.id_recurso = :rec_desc;
\echo '--- 12.2 descartar sin motivo (ESPERADO: ERROR)'
CALL sp_descartar_recurso(:rec_desc, 2, 3, '');
\echo '--- 12.3 coordinador hospitalario no puede descartar (ESPERADO: ERROR)'
CALL sp_descartar_recurso(:rec_desc, 2, 6, 'x');
\echo '--- 12.4 descartar algo ya Utilizado (ESPERADO: ERROR)'
SELECT id_recurso AS rec_usado FROM asignaciones WHERE id_asignacion = :asig1 \gset
CALL sp_descartar_recurso(:rec_usado, 4, 3, 'Prueba');
\echo '--- 12.5 descartar un recurso Reservado (ESPERADO: Descartado, asignacion Cancelada, solicitud En proceso)'
CALL sp_registrar_solicitud_sangre(4, 6, 2, 1, 1, 24, 'Reserva para cirugia', NULL, NULL) \gset
\set sol4 :p_id_solicitud
SELECT m.id_matching AS m4, m.id_recurso AS rec4 FROM matching m JOIN solicitudes_detalle sd USING (id_solicitud_detalle)
WHERE sd.id_solicitud = :sol4 AND m.disponible ORDER BY fn_puntaje_matching(m.id_matching) DESC, m.id_matching LIMIT 1 \gset
CALL sp_asignar_recurso(:m4, 2, 'Compatible', NULL) \gset
CALL sp_descartar_recurso(:rec4, 2, 3, 'Se rompio la bolsa en el refrigerador');
SELECT er.nombre AS recurso, ea.nombre AS asignacion, es.nombre AS solicitud
FROM asignaciones a JOIN recursos r ON r.id_recurso = a.id_recurso
JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
JOIN cat_estados_asignacion ea ON ea.id_estado_asignacion = a.id_estado_asignacion
JOIN solicitudes s ON s.id_solicitud = :sol4
JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud
WHERE a.id_asignacion = :p_id_asignacion;

\echo '=================== SP13 sp_registrar_organo ==================='
\echo '--- 13.1 rinon sin lado (ESPERADO: ERROR)'
CALL sp_registrar_organo(6, 1, 1, NULL, 150, 11.5, 30, NULL);
\echo '--- 13.2 rreyes registra rinon izquierdo del donante 1 (ESPERADO: recurso Disponible, En evaluacion)'
CALL sp_registrar_organo(6, 1, 1, 1, 150, 11.5, 30, NULL) \gset
\set organo1 :p_id_recurso
SELECT r.folio, er.nombre AS estado, ev.nombre AS viabilidad FROM recursos r
JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
JOIN organos o ON o.id_recurso = r.id_recurso
JOIN cat_viabilidad_organo ev ON ev.id_viabilidad_organo = o.id_viabilidad_organo WHERE r.id_recurso = :organo1;
\echo '--- 13.3 institucion sin Procuracion de organos: eesquivel del banco (ESPERADO: ERROR)'
CALL sp_registrar_organo(5, 1, 2, NULL, 1500, 20, 12, NULL);
\echo '--- 13.4 corazon con lado (ESPERADO: ERROR)'
CALL sp_registrar_organo(6, 1, 3, 1, 300, 12, 6, NULL);
\echo '--- 13.5 la evaluacion se hace desde Flask (INSERT + UPDATE); aqui se simula que quedo Viable'
INSERT INTO evaluaciones_organo (id_recurso, id_personal, fecha_hora, id_tipo_evaluacion, id_resultado_evaluacion, observaciones)
VALUES (:organo1, 6, now(), 1, 1, 'Buena perfusion');
UPDATE organos SET id_viabilidad_organo = 1 WHERE id_recurso = :organo1;

\echo '=================== SP14 sp_registrar_solicitud_organo + SP6 (organo) ==================='
\echo '--- 14.1 atamez pide un rinon para el receptor 2 (A+) de 10 a 13 cm (ESPERADO: 1 candidato)'
CALL sp_registrar_solicitud_organo(2, 17, 1, 1, 10, 13, 12, 'Insuficiencia renal cronica', NULL, NULL) \gset
\set sol_organo :p_id_solicitud
\echo 'solicitud =' :sol_organo ' candidatos =' :p_candidatos
SELECT id_solicitud_detalle AS det_organo FROM solicitudes_detalle WHERE id_solicitud = :sol_organo \gset
SELECT r.folio, ts.nombre AS tipo, fn_puntaje_matching(m.id_matching) AS puntaje, m.explicacion
FROM matching m JOIN recursos r ON r.id_recurso = m.id_recurso
JOIN cat_tipos_sanguineo ts ON ts.id_tipo_sanguineo = r.id_tipo_sanguineo
WHERE m.id_solicitud_detalle = :det_organo AND m.disponible;
\echo '--- 14.2 sin motivo (ESPERADO: ERROR)'
CALL sp_registrar_solicitud_organo(2, 17, 1, 1, 10, 13, 12, '', NULL, NULL);
\echo '--- 14.3 hospital sin Trasplante: vgonzalez del Materno Infantil (ESPERADO: ERROR)'
CALL sp_registrar_solicitud_organo(2, 11, 1, 1, 10, 13, 12, 'Prueba', NULL, NULL);
\echo '--- 14.4 tamano minimo mayor al maximo (ESPERADO: ERROR)'
CALL sp_registrar_solicitud_organo(2, 17, 1, 1, 14, 10, 12, 'Prueba', NULL, NULL);
\echo '--- 6.4 recalcular el matching del organo con el mismo SP6 (ESPERADO: 1)'
CALL sp_generar_matching(:det_organo, NULL);

\echo '=================== Flujo del organo: asignar, trasladar y recibir ==================='
SELECT id_matching AS match_organo FROM matching WHERE id_solicitud_detalle = :det_organo AND disponible ORDER BY id_matching LIMIT 1 \gset
CALL sp_asignar_recurso(:match_organo, 2, 'Unico rinon compatible', NULL) \gset
\set asig_organo :p_id_asignacion
\echo '--- 11.4 transfundir un organo (ESPERADO: ERROR)'
CALL sp_registrar_transfusion(:asig_organo, 18, 1, NULL);
\echo '--- 15.1 trasplante antes de que llegue el organo (ESPERADO: ERROR)'
CALL sp_registrar_trasplante(:asig_organo, 18, NULL);
CALL sp_programar_traslado(:asig_organo, 4, 2, 45, NULL) \gset
\set tras_organo :p_id_traslado
CALL sp_registrar_recepcion(:tras_organo, 17, 1, NULL, NULL);

\echo '=================== SP15 sp_registrar_trasplante ==================='
\echo '--- 15.2 atamez no tiene Registrar utilizacion de recursos (ESPERADO: ERROR)'
CALL sp_registrar_trasplante(:asig_organo, 17, NULL);
\echo '--- 15.3 medico de otro hospital: dgarza (ESPERADO: ERROR)'
CALL sp_registrar_trasplante(:asig_organo, 8, NULL);
\echo '--- 15.4 iibarra registra el trasplante (ESPERADO: operacion Trasplante, solicitud Atendida, recurso Utilizado)'
CALL sp_registrar_trasplante(:asig_organo, 18, NULL) \gset
SELECT o.id_operacion, tot.nombre AS tipo, eo.nombre AS estado FROM operaciones o
JOIN cat_tipos_operacion tot ON tot.id_tipo_operacion = o.id_tipo_operacion
JOIN cat_estados_operacion eo ON eo.id_estado_operacion = o.id_estado_operacion WHERE o.id_operacion = :p_id_operacion;
SELECT es.nombre AS solicitud FROM solicitudes s JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud
WHERE s.id_solicitud = :sol_organo;
SELECT er.nombre AS recurso FROM recursos r JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
WHERE r.id_recurso = :organo1;
\echo '--- 15.5 registrar el trasplante otra vez (ESPERADO: ERROR)'
CALL sp_registrar_trasplante(:asig_organo, 18, NULL);
\echo '--- 15.6 trasplante con una asignacion de sangre (ESPERADO: ERROR)'
CALL sp_registrar_trasplante(:asig1, 6, NULL);

\echo '=================== SP16 sp_cancelar_solicitud ==================='
\echo '--- 16.1 nueva solicitud con un recurso Reservado (se cancela despues)'
CALL sp_registrar_solicitud_sangre(4, 6, 3, 2, 1, 24, 'Plasma para cirugia', NULL, NULL) \gset
\set sol5 :p_id_solicitud
SELECT m.id_matching AS m5, m.id_recurso AS rec5 FROM matching m JOIN solicitudes_detalle sd USING (id_solicitud_detalle)
WHERE sd.id_solicitud = :sol5 AND m.disponible ORDER BY fn_puntaje_matching(m.id_matching) DESC, m.id_matching LIMIT 1 \gset
CALL sp_asignar_recurso(:m5, 2, 'Compatible', NULL) \gset
\set asig5 :p_id_asignacion
\echo '--- 16.2 sin motivo (ESPERADO: ERROR)'
CALL sp_cancelar_solicitud(:sol5, 6, '', NULL);
\echo '--- 16.3 sin permiso Gestionar reservas: dgarza (ESPERADO: ERROR)'
CALL sp_cancelar_solicitud(:sol5, 8, 'Prueba', NULL);
\echo '--- 16.4 coordinador de otro hospital: atamez (ESPERADO: ERROR solo tu institucion)'
CALL sp_cancelar_solicitud(:sol5, 17, 'Prueba', NULL);
\echo '--- 16.5 rreyes cancela (ESPERADO: 1 liberado, solicitud Cancelada, reserva Liberada, recurso Disponible)'
CALL sp_cancelar_solicitud(:sol5, 6, 'El paciente fue dado de alta', NULL);
SELECT es.nombre AS solicitud, ea.nombre AS asignacion, rs.nombre AS reserva, er.nombre AS recurso
FROM asignaciones a
JOIN cat_estados_asignacion ea ON ea.id_estado_asignacion = a.id_estado_asignacion
JOIN reservas rv ON rv.id_asignacion = a.id_asignacion
JOIN cat_estados_reserva rs ON rs.id_estado_reserva = rv.id_estado_reserva
JOIN recursos r ON r.id_recurso = a.id_recurso
JOIN cat_estados_recurso er ON er.id_estado_recurso = r.id_estado_recurso
JOIN solicitudes s ON s.id_solicitud = :sol5
JOIN cat_estados_solicitud es ON es.id_estado_solicitud = s.id_estado_solicitud
WHERE a.id_asignacion = :asig5;
\echo '--- 16.6 cancelar otra vez (ESPERADO: ERROR ya Cancelada)'
CALL sp_cancelar_solicitud(:sol5, 6, 'Otra vez', NULL);
\echo '--- 16.7 cancelar una solicitud Atendida (ESPERADO: ERROR)'
CALL sp_cancelar_solicitud(:sol1, 6, 'Prueba', NULL);

\echo '=================== FUNCIONES (SELECT) ==================='
SELECT fn_calcular_edad('2000-05-10') AS edad,
       fn_verificar_password('Demo2026!', crypt('Demo2026!', gen_salt('bf'))) AS hash_ok,
       fn_compatible_sangre('O-', 'A+', 1) AS o_neg_a_mas_eritro,
       fn_compatible_sangre('A+', 'O+', 1) AS a_mas_a_o_mas_eritro,
       fn_compatible_sangre('AB+', 'O-', 2) AS plasma_ab_a_o,
       fn_distancia_km(25.699, -100.367, 25.6876, -100.3498) AS km_banco_hospital,
       fn_tiene_permiso(2, 'Aprobar asignaciones') AS coord_aprueba,
       fn_institucion_ofrece(1, 2) AS banco_transfunde,
       fn_compatible_sangre('O-', 'A+', 0) AS organo_o_a_a,
       fn_compatible_sangre('A+', 'O+', 0) AS organo_a_a_o;
