// IBM FlashSystem GUI
// IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
// Registration via PVE.Utils.storageSchema

(function () {
    let attempts = 0;
    const maxAttempts = 100;

    function initPlugin() {
        // Wait for PVE.Utils.storageSchema and PVE.panel.StorageBase
        if (window.Ext && window.PVE && PVE.Utils && PVE.Utils.storageSchema && PVE.panel && PVE.panel.StorageBase) {
            try {
                // ============================================================
                // IBM FlashSystem Input Panel (for Add/Edit dialog)
                // MUST extend PVE.panel.StorageBase (like DirInputPanel, LVMInputPanel, etc.)
                // ============================================================
                Ext.define('PVE.storage.IBMFlashInputPanel', {
                    extend: 'PVE.panel.StorageBase',
                    alias: 'widget.pveIBMFlashInputPanel',

                    onlineHelp: 'storage_ibmflash',

                    initComponent: function () {
                        let me = this;

                        me.column1 = [
                            {
                                xtype: 'proxmoxtextfield',
                                name: 'portal',
                                fieldLabel: gettext('Portal'),
                                allowBlank: false,
                                emptyText: '10.0.0.1',
                            },
                            {
                                xtype: 'proxmoxtextfield',
                                name: 'port',
                                fieldLabel: gettext('Port'),
                                emptyText: '7443',
                            },
                            {
                                xtype: 'proxmoxtextfield',
                                name: 'pool',
                                fieldLabel: gettext('Pool'),
                                allowBlank: false,
                                emptyText: 'mdiskgrp0',
                            },
                            {
                                xtype: 'proxmoxtextfield',
                                name: 'hostcluster',
                                fieldLabel: gettext('Host Cluster'),
                                allowBlank: false,
                                emptyText: 'ProxmoxCluster',
                            },
                            {
                                xtype: 'proxmoxtextfield',
                                name: 'username',
                                fieldLabel: gettext('User Name'),
                                allowBlank: false,
                                emptyText: 'supervisor',
                            },
                            {
                                xtype: 'proxmoxtextfield',
                                inputType: 'password',
                                name: 'password',
                                fieldLabel: gettext('Password'),
                                allowBlank: !me.isCreate,
                                emptyText: me.isCreate ? '' : gettext('Unchanged'),
                            },
                            {
                                xtype: 'proxmoxKVComboBox',
                                name: 'protocol',
                                fieldLabel: gettext('Protocol'),
                                value: 'fc',
                                allowBlank: false,
                                disabled: !me.isCreate,  // Read-only after creation (fixed)
                                comboItems: [
                                    ['fc', 'FC (Fibre Channel)'],
                                ],
                            },
                        ];

                        me.column2 = [
                            {
                                xtype: 'pveContentTypeSelector',
                                name: 'content',
                                value: 'images',
                                multiSelect: true,
                                fieldLabel: gettext('Content'),
                                allowBlank: false,
                            },
                            {
                                xtype: 'proxmoxintegerfield',
                                name: 'max_retries',
                                fieldLabel: gettext('Max Retries'),
                                minValue: 0,
                                maxValue: 10,
                                value: 3,
                                emptyText: '3',
                            },
                            {
                                xtype: 'proxmoxintegerfield',
                                name: 'retry_delay',
                                fieldLabel: gettext('Retry Delay'),
                                minValue: 1,
                                maxValue: 60,
                                value: 5,
                                emptyText: '5',
                            },
                            {
                                xtype: 'proxmoxintegerfield',
                                name: 'timeout',
                                fieldLabel: gettext('Timeout'),
                                minValue: 5,
                                maxValue: 300,
                                value: 30,
                                emptyText: '30',
                            },
                            {
                                xtype: 'proxmoxcheckbox',
                                name: 'verify_ssl',
                                fieldLabel: gettext('Verify SSL'),
                                uncheckedValue: 0,
                                checked: false,
                            },
                        ];

                        me.advancedColumn1 = [
                            {
                                xtype: 'proxmoxcheckbox',
                                name: 'shared',
                                fieldLabel: gettext('Shared'),
                                uncheckedValue: 0,
                                checked: true,
                            },
                        ];

                        me.advancedColumn2 = [
                            {
                                xtype: 'proxmoxintegerfield',
                                name: 'debug',
                                fieldLabel: gettext('Debug Level'),
                                minValue: 0,
                                maxValue: 2,
                                value: 0,
                            },
                        ];

                        me.callParent();
                    },
                });

                // ============================================================
                // Register IBM FlashSystem in storageSchema
                // ============================================================
                PVE.Utils.storageSchema.ibmflash = {
                    name: gettext('IBM FlashSystem'),
                    ipanel: 'IBMFlashInputPanel',
                    faIcon: 'building',
                    backups: false,
                };

                console.log('IBM FlashSystem registered in PVE.Utils.storageSchema!');
                console.log('IBMFlashInputPanel extends:', PVE.storage.IBMFlashInputPanel.superclass.$className);

            } catch (e) {
                console.error('Failed to initialize IBM FlashSystem plugin:', e);
            }
        } else if (attempts < maxAttempts) {
            attempts++;
            setTimeout(initPlugin, 100);
        } else {
            console.error('Required components not found after 10 seconds');
            console.log('PVE.Utils.storageSchema:', typeof window.PVE?.Utils?.storageSchema);
            console.log('PVE.panel.StorageBase:', typeof window.PVE?.panel?.StorageBase);
        }
    }

    initPlugin();
})();
