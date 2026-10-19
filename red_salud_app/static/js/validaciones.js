/* Validaciones del lado del cliente (el servidor vuelve a validar todo).
   Se aplican a los formularios con class="validar" y a los que tienen data-confirmar. */
(function () {
  'use strict';

  function hoy() {
    var d = new Date();
    d.setHours(0, 0, 0, 0);
    return d;
  }

  function edad(fecha) {
    var h = new Date();
    var e = h.getFullYear() - fecha.getFullYear();
    var m = h.getMonth() - fecha.getMonth();
    if (m < 0 || (m === 0 && h.getDate() < fecha.getDate())) { e--; }
    return e;
  }

  function marcar(campo, mensaje) {
    campo.classList.add('invalido');
    var div = document.createElement('div');
    div.className = 'error-campo';
    div.textContent = mensaje;
    campo.insertAdjacentElement('afterend', div);
  }

  function limpiar(form) {
    form.querySelectorAll('.error-campo').forEach(function (d) { d.remove(); });
    form.querySelectorAll('.invalido').forEach(function (c) { c.classList.remove('invalido'); });
  }

  function validar(form) {
    limpiar(form);
    var errores = 0;
    var campos = form.querySelectorAll('input, select, textarea');

    campos.forEach(function (c) {
      if (c.type === 'hidden' || c.disabled) { return; }
      var valor = (c.value || '').trim();

      // obligatorios: no se aceptan solo espacios
      if (c.required && valor === '') {
        marcar(c, 'Este campo es obligatorio.'); errores++; return;
      }
      if (valor === '') { return; }

      // reglas nativas de HTML5 (pattern, min, max, maxlength, type=email...)
      if (!c.checkValidity()) {
        marcar(c, c.title || c.validationMessage); errores++; return;
      }

      // fecha que no puede ser futura y rango de edad
      if (c.type === 'date' && c.hasAttribute('data-no-futura')) {
        var f = new Date(valor + 'T00:00:00');
        if (f > hoy()) { marcar(c, 'La fecha no puede ser futura.'); errores++; return; }
        var min = parseInt(c.getAttribute('data-edad-min'), 10);
        var max = parseInt(c.getAttribute('data-edad-max'), 10);
        var e = edad(f);
        if (!isNaN(min) && e < min) { marcar(c, 'Debe tener al menos ' + min + ' años (tiene ' + e + ').'); errores++; return; }
        if (!isNaN(max) && e > max) { marcar(c, 'Debe tener como máximo ' + max + ' años (tiene ' + e + ').'); errores++; return; }
      }

      // fecha y hora que debe ser futura
      if (c.type === 'datetime-local' && c.hasAttribute('data-futura')) {
        if (new Date(valor) <= new Date()) { marcar(c, 'Debe ser una fecha posterior a este momento.'); errores++; return; }
      }

      // un número que debe ser menor o igual que otro campo (tamaño mínimo <= máximo)
      if (c.hasAttribute('data-menor-que')) {
        var otro = form.querySelector('#' + c.getAttribute('data-menor-que'));
        if (otro && otro.value !== '' && parseFloat(valor) > parseFloat(otro.value)) {
          marcar(c, 'Debe ser menor o igual que el máximo.'); errores++; return;
        }
      }

      // confirmación de contraseña
      if (c.hasAttribute('data-igual-a')) {
        var original = form.querySelector('#' + c.getAttribute('data-igual-a'));
        if (original && original.value !== c.value) { marcar(c, 'Las contraseñas no coinciden.'); errores++; return; }
      }
    });

    // contraseña nueva: letras y números
    var pass = form.querySelector('input[autocomplete="new-password"]#password');
    if (pass && pass.value && (!/[A-Za-z]/.test(pass.value) || !/\d/.test(pass.value))) {
      marcar(pass, 'Usa letras y números.'); errores++;
    }
    return errores === 0;
  }

  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('form').forEach(function (form) {
      if (form.classList.contains('validar')) { form.setAttribute('novalidate', 'novalidate'); }
      form.addEventListener('submit', function (ev) {
        if (form.classList.contains('validar') && !validar(form)) {
          ev.preventDefault();
          var primero = form.querySelector('.invalido');
          if (primero) { primero.focus(); }
          return;
        }
        var pregunta = form.getAttribute('data-confirmar');
        if (pregunta && !window.confirm(pregunta)) { ev.preventDefault(); }
      });
    });
  });
})();
