-- Agente de vencimientos de Ocre (solo lectura).
-- Una fila por alerta. Usa la misma cuenta que el CRM:
--   venta = tarifa por persona × pasajeros; costo de un servicio = costo por persona × pasajeros.
-- Días hábiles: lunes a viernes, sin los feriados cargados en Configuración (crm_meta 'cfg' → feriados).
--   pagar_antes  = vencimiento del proveedor − N días hábiles (cfg.diasPagoProv, por defecto 3)
--   limite_cli   = primer pagar_antes de la reserva − M días hábiles (cfg.diasCliente, por defecto 2)
with hoy as (select (now() at time zone 'America/Argentina/Buenos_Aires')::date as d),
cfg as (select data from crm_meta where clave = 'cfg'),
par as (select coalesce((select (data->>'diasPagoProv')::int from cfg), 3) np,
               coalesce((select (data->>'diasCliente')::int from cfg), 2) nc),
fer as (select left(x,10)::date f from cfg, jsonb_array_elements_text(coalesce(cfg.data->'feriados','[]'::jsonb)) x
        where x ~ '^\d{4}-\d{2}-\d{2}'),
base as (
  select r.id, r.data, r.data->>'titulo' titulo, coalesce(r.data->>'moneda','ARS') moneda, r.data->>'estado' estado,
    case when r.data->>'salida' ~ '^(19|20)\d\d-\d\d-\d\d$' then (r.data->>'salida')::date end salida,
    case when r.data->>'vtoSaldo' ~ '^(19|20)\d\d-\d\d-\d\d$' then (r.data->>'vtoSaldo')::date end vto_saldo,
    r.data->>'salida' salida_txt,
    case when jsonb_array_length(coalesce(r.data->'pasajeros','[]'::jsonb))>0 then jsonb_array_length(r.data->'pasajeros')
         when r.data->>'paxEstimados' ~ '^[0-9]+$' then (r.data->>'paxEstimados')::int else 0 end pax,
    case when r.data->>'tarifaPax' ~ '^[0-9]+(\.[0-9]+)?$' then (r.data->>'tarifaPax')::numeric else 0 end tarifa,
    c.nombre cliente
  from crm_reservas r left join crm_clientes c on c.id = r.data->>'clienteId'),
cob as (select data->>'reservaId' rid, sum((data->>'aplicado')::numeric) cobrado from crm_cobros
        where coalesce(data->>'anulado','false') <> 'true' group by 1),
pag as (select data->>'servicioId' sid, sum(case when data->>'monto' ~ '^[0-9]+(\.[0-9]+)?$' then (data->>'monto')::numeric else 0 end) pagado
        from crm_pagos_prov group by 1),
cli as (select b.*, b.tarifa*b.pax - coalesce(cob.cobrado,0) saldo from base b left join cob on cob.rid = b.id
        where coalesce(b.estado,'') <> 'Cancelada'),
svc as (
  select cli.id rid, cli.titulo, cli.moneda, cli.salida, s->>'id' sid, s->>'tipo' tipo, p.nombre proveedor,
    case when s->>'costo' ~ '^[0-9]+(\.[0-9]+)?$' then (s->>'costo')::numeric else 0 end * cli.pax
      - coalesce(pag.pagado,0) deuda,
    case when s->>'vtoPago' ~ '^(19|20)\d\d-\d\d-\d\d$' then (s->>'vtoPago')::date end vto_pago
  from cli cross join jsonb_array_elements(coalesce(cli.data->'servicios','[]'::jsonb)) s
  left join pag on pag.sid = s->>'id' left join crm_proveedores p on p.id = s->>'proveedorId'
  where coalesce(s->>'estado','') <> 'Cancelado'),
svc2 as (
  select svc.*, (select x::date from generate_series(svc.vto_pago - 1, svc.vto_pago - 60, interval '-1 day') x
                 where extract(isodow from x) < 6 and x::date not in (select f from fer)
                 order by x desc offset (select np from par) - 1 limit 1) pagar_antes
  from svc where svc.vto_pago is not null),
lim as (
  select l.rid, l.pagar_antes, l.proveedor,
    (select x::date from generate_series(l.pagar_antes - 1, l.pagar_antes - 60, interval '-1 day') x
     where extract(isodow from x) < 6 and x::date not in (select f from fer)
     order by x desc offset (select nc from par) - 1 limit 1) limite_cli
  from (select distinct on (rid) rid, pagar_antes, proveedor from svc2 where deuda > 0.5 order by rid, pagar_antes) l),
canc as (select b.*, coalesce(cob.cobrado,0) cobrado,
    case when b.data->>'fechaCancel' ~ '^(19|20)\d\d-\d\d-\d\d$' then (b.data->>'fechaCancel')::date end fecha_cancel
  from base b left join cob on cob.rid = b.id where b.estado = 'Cancelada')

select 'DEVOLUCIÓN PENDIENTE' tipo, id reserva, titulo, cliente quien,
       round((data->'devolucion'->>'monto')::numeric) monto, moneda, fecha_cancel vence,
       fecha_cancel - (select d from hoy) dias,
       'Cancelada el '||to_char(fecha_cancel,'DD/MM')||'. Retención: penalidad '||coalesce(data->'devolucion'->>'penalidad','0')
         ||' + gestión '||coalesce(data->'devolucion'->>'gestion','0') detalle
  from canc where data->'devolucion'->>'estado' = 'Pendiente' and coalesce(data->'devolucion'->>'forma','') <> 'Crédito a favor'
union all
select 'COBRO CLIENTE', id, titulo, cliente, round(saldo), moneda, vto_saldo, vto_saldo - (select d from hoy), ''
  from cli where saldo > 0.5 and vto_saldo is not null and vto_saldo <= (select d from hoy) + 7
union all
select 'PAGO PROVEEDOR', rid, titulo, coalesce(proveedor,'(sin proveedor)')||' · '||tipo, round(deuda), moneda, pagar_antes,
       pagar_antes - (select d from hoy), 'Pagar a más tardar el '||to_char(pagar_antes,'DD/MM')||' (el proveedor vence el '||to_char(vto_pago,'DD/MM')||')'
  from svc2 where deuda > 0.5 and pagar_antes <= (select d from hoy) + 7
union all
select 'REVISAR', id, titulo, cliente, null, moneda, null::date, null, 'Fecha de salida inválida ('||salida_txt||')'
  from base where salida is null and coalesce(salida_txt,'') <> ''
union all
select 'REVISAR', cli.id, cli.titulo, cli.cliente, round(cli.saldo), cli.moneda, cli.vto_saldo, null,
  'El cliente vence el '||to_char(cli.vto_saldo,'DD/MM')||' y tendría que vencer a más tardar el '||to_char(lim.limite_cli,'DD/MM')
    ||' (tenés que pagarle a '||coalesce(lim.proveedor,'un proveedor')||' antes del '||to_char(lim.pagar_antes,'DD/MM')||')'
  from cli join lim on lim.rid = cli.id where cli.saldo > 0.5 and cli.vto_saldo > lim.limite_cli
union all
select 'REVISAR', id, titulo, cliente, round(saldo), moneda, null::date, null, 'Tiene saldo pendiente y no tiene fecha de vencimiento'
  from cli where saldo > 0.5 and vto_saldo is null and salida <= (select d from hoy) + 30
union all
select 'REVISAR', rid, titulo, coalesce(proveedor,'(sin proveedor)')||' · '||tipo, round(deuda), moneda, null::date, null,
  'Deuda con el proveedor sin fecha de vencimiento'
  from svc where deuda > 0.5 and vto_pago is null and salida <= (select d from hoy) + 30
union all
select 'REVISAR', id, titulo, cliente, null, moneda, null::date, null,
  'Reserva cancelada con servicios todavía activos: pasalos a Cancelado y registrá lo que devuelva cada proveedor'
  from canc where exists (select 1 from jsonb_array_elements(coalesce(data->'servicios','[]'::jsonb)) s
                          where coalesce(s->>'estado','') <> 'Cancelado')
union all
select 'LEGAJO PROVEEDOR', id, nombre, k, null, null, (data->>k)::date, (data->>k)::date - (select d from hoy), 'Vence '||k
  from crm_proveedores, unnest(array['vtoHabilitacion','vtoPoliza','vtoRTO']) k
  where data->>k ~ '^(19|20)\d\d-\d\d-\d\d$' and (data->>k)::date <= (select d from hoy) + 30
order by 1, 8 nulls last;
