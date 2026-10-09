# Custom addons

Put your own Odoo 18 modules here (one directory per module). They are copied
into the image at `/mnt/extra-addons`, which is already on the addons path.

To install a module, add it to `odoo.init.installModules` in
`environments/<env>/values.yaml`. To upgrade it on a later deploy, pass it in
the Jenkins `ODOO_UPDATE_MODULES` parameter.
