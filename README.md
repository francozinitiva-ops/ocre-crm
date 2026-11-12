# Ocre · CRM

Sistema de gestión de Ocre (reservas, clientes, proveedores, cobros, leads, egresos y mensajes de cotización para WhatsApp).

- **Respaldo:** automático, los lunes a las 22 h, en el repositorio privado `ocre-respaldos`.

- **App:** `index.html`. Es un solo archivo, publicado con GitHub Pages.
- **Datos:** Supabase, proyecto «OCRE TURISMO» (antes «AL OESTE»). Cada sección del CRM es una tabla `crm_*` con `id` y `data` (jsonb).
- **Acceso:** usuarios de Supabase Auth que estén cargados en `crm_usuarios`. Las políticas de seguridad (RLS) bloquean todo lo demás.
- **Esquema:** `supabase_schema.sql`. Se puede volver a correr sin romper nada.

La clave que figura en `index.html` es la clave **pública** de Supabase, pensada para ir en el navegador. Nunca subir acá la clave secreta (service_role).

## Habilitar un usuario

1. Supabase → Authentication → Users → Add user (con «Auto Confirm User»).
2. SQL Editor:

```sql
insert into public.crm_usuarios (user_id, email, nombre)
select id, email, 'Nombre' from auth.users where email = 'email@ejemplo.com';
```

## Consultas de la web → leads del CRM

`supabase_leads_web.sql` instala una regla en la base: cada consulta que entra por el formulario de la web (`public.leads`) crea un lead en el CRM con el siguiente número `LEA-xxxx`, canal «Web», etapa «Nuevo» y seguimiento para el día. Si la experiencia elegida nombra un destino del catálogo, queda asociado a ese destino. Si algo falla del lado del CRM, la consulta de la web se guarda igual.
