-- Agente de vencimientos de Ocre (solo lectura).
-- Devuelve una fila por alerta: cobros de clientes y pagos a proveedores que vencen en los próximos 7 días
-- (o ya vencidos y sin saldar), incoherencias de fechas y vencimientos del legajo de proveedores (30 días).
-- Usa la misma cuenta que el CRM: venta = tarifa por persona × pasajeros; costo de servicio = costo por persona × pasajeros.
with hoy as (select (now() at time zone 'America/Argentina/Buenos_Aires')::date as d),
res as (
  select r.id, r.data->>'titulo' titulo, coalesce(r.data->>'moneda','ARS') moneda, r.data->>'clienteId' cliente_id,
    case when r.data->>'salida' ~ '^(19|20)\d\d-\d\d-\d\d$' then (r.data->>'salida')::date end salida,
    case when r.data->>'vtoSaldo' ~ '^(19|20)\d\d-\d\d-\d\d$' then (r.data->>'vtoSaldo')::date end vto_saldo,
    r.data->>'salida' salida_txt,
    case when jsonb_array_length(coalesce(r.data->'pasajeros','[]'::jsonb))>0 then jsonb_array_length(r.data->'pasajeros')
         when r.data->>'paxEstimados' ~ '^[0-9]+$' then (r.data->>'paxEstimados')::int else 0 end pax,
    case when r.data->>'tarifaPax' ~ '^[0-9]+(\.[0-9]+)?$' then (r.data->>'tarifaPax')::numeric else 0 end tarifa,
    r.data->'servicios' servicios
  from crm_reservas r where coalesce(r.data->>'estado','') <> 'Cancelada'),
cob as (select data->>'reservaId' rid, sum((data->>'aplicado')::numeric) cobrado from crm_cobros
        where coalesce(data->>'anulado','false') <> 'true' group by 1),
cli as (
  select res.*, res.tarifa*res.pax - coalesce(cob.cobrado,0) saldo, c.nombre cliente
  from res left join cob on cob.rid = res.id left join crm_clientes c on c.id = res.cliente_id),
svc as (
  select cli.id rid, cli.titulo, cli.moneda, cli.salida, s->>'id' sid, s->>'tipo' tipo, s->>'proveedorId' pid,
    case when s->>'costo' ~ '^[0-9]+(\.[0-9]+)?$' then (s->>'costo')::numeric else 0 end * cli.pax costo_total,
    case when s->>'vtoPago' ~ '^(19|20)\d\d-\d\d-\d\d$' then (s->>'vtoPago')::date end vto_pago
  from cli, jsonb_array_elements(coalesce(cli.servicios,'[]'::jsonb)) s where coalesce(s->>'estado','') <> 'Cancelado'),
pag as (select data->>'servicioId' sid, sum(case when data->>'monto' ~ '^[0-9]+(\.[0-9]+)?$' then (data->>'monto')::numeric else 0 end) pagado
        from crm_pagos_prov group by 1),
svc2 as (select svc.*, svc.costo_total - coalesce(pag.pagado,0) deuda, p.nombre proveedor
         from svc left join pag on pag.sid = svc.sid left join crm_proveedores p on p.id = svc.pid)
select 'COBRO CLIENTE' tipo, id reserva, titulo, cliente quien, round(saldo) monto, moneda, vto_saldo vence,
       vto_saldo - (select d from hoy) dias, '' detalle
  from cli where saldo > 0.5 and vto_saldo is not null and vto_saldo <= (select d from hoy) + 7
union all
select 'PAGO PROVEEDOR', rid, titulo, coalesce(proveedor,'(sin proveedor)')||' · '||tipo, round(deuda), moneda, vto_pago,
       vto_pago - (select d from hoy), ''
  from svc2 where deuda > 0.5 and vto_pago is not null and vto_pago <= (select d from hoy) + 7
union all
select 'REVISAR', id, titulo, cliente, null, moneda, null::date, null, 'Fecha de salida inválida ('||salida_txt||')'
  from cli where salida is null and coalesce(salida_txt,'') <> ''
union all
select 'REVISAR', id, titulo, cliente, round(saldo), moneda, vto_saldo, null,
  case when vto_saldo > salida then 'El saldo del cliente vence después de la salida'
       else 'Tiene saldo pendiente y no tiene fecha de vencimiento' end
  from cli where saldo > 0.5 and (vto_saldo > salida or (vto_saldo is null and salida <= (select d from hoy) + 30))
union all
select 'REVISAR', rid, titulo, coalesce(proveedor,'(sin proveedor)')||' · '||tipo, round(deuda), moneda, vto_pago, null,
  case when vto_pago > salida then 'El pago al proveedor vence después de la salida'
       else 'Deuda con el proveedor sin fecha de vencimiento' end
  from svc2 where deuda > 0.5 and (vto_pago > salida or (vto_pago is null and salida <= (select d from hoy) + 30))
union all
select 'LEGAJO PROVEEDOR', id, nombre, k, null, null, (data->>k)::date, (data->>k)::date - (select d from hoy), 'Vence '||k
  from crm_proveedores, unnest(array['vtoHabilitacion','vtoPoliza','vtoRTO']) k
  where data->>k ~ '^(19|20)\d\d-\d\d-\d\d$' and (data->>k)::date <= (select d from hoy) + 30
order by 1, 8 nulls last;
