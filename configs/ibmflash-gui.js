// IBM FlashSystem GUI
// IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE
// GUI Integration - Injected into pvemanagerlib.js

// IBM FlashSystem Storage Edit Dialog
Ext.define('PVE.storage.IBMFlashEdit', {
    extend: 'PVE.storage.BaseEdit',
    alias: 'widget.pveStorageIBMFlashEdit',

    onlineHelp: 'storage_ibmflash',

    initComponent: function() {
        var me = this;

        me.column1 = [
            {
                xtype: 'pveTextField',
                name: 'portal',
                fieldLabel: gettext('Portal'),
                allowBlank: false,
                emptyText: '10.0.0.1',
                submitValue: true,
            },
            {
                xtype: 'pveTextField',
                name: 'port',
                fieldLabel: gettext('Port'),
                emptyText: '7443',
                submitValue: true,
            },
            {
                xtype: 'pveTextField',
                name: 'pool',
                fieldLabel: gettext('Pool'),
                allowBlank: false,
                emptyText: 'mdiskgrp0',
                submitValue: true,
            },
            {
                xtype: 'pveTextField',
                name: 'hostcluster',
                fieldLabel: gettext('Host Cluster'),
                allowBlank: false,
                emptyText: 'ProxmoxCluster',
                submitValue: true,
            },
            {
                xtype: 'textfield',
                inputType: 'password',
                name: 'password',
                fieldLabel: gettext('Password'),
                allowBlank: false,
                submitValue: true,
            },
        ];

        me.column2 = [
            {
                xtype: 'pveContentTypeSelector',
                cts: ['images', 'rootdir'],
                fieldLabel: gettext('Content'),
                value: ['images'],
                submitValue: true,
            },
            {
                xtype: 'pveIntegerField',
                name: 'max_retries',
                fieldLabel: gettext('Max Retries'),
                minValue: 0,
                maxValue: 10,
                value: 3,
                emptyText: '3',
                submitValue: true,
            },
            {
                xtype: 'pveIntegerField',
                name: 'retry_delay',
                fieldLabel: gettext('Retry Delay'),
                minValue: 1,
                maxValue: 60,
                value: 5,
                emptyText: '5',
                submitValue: true,
            },
            {
                xtype: 'pveIntegerField',
                name: 'timeout',
                fieldLabel: gettext('Timeout'),
                minValue: 5,
                maxValue: 300,
                value: 30,
                emptyText: '30',
                submitValue: true,
            },
            {
                xtype: 'pvecheckbox',
                name: 'verify_ssl',
                fieldLabel: gettext('Verify SSL'),
                uncheckedValue: 0,
                checked: false,
                submitValue: true,
            },
        ];

        me.advancedColumn1 = [
            {
                xtype: 'pvecheckbox',
                name: 'shared',
                fieldLabel: gettext('Shared'),
                uncheckedValue: 0,
                checked: true,
                submitValue: true,
            },
        ];

        me.advancedColumn2 = [
            {
                xtype: 'pveIntegerField',
                name: 'debug',
                fieldLabel: gettext('Debug Level'),
                minValue: 0,
                maxValue: 2,
                value: 0,
                submitValue: true,
            },
        ];

        me.callParent();
    },
});

// Register IBM FlashSystem storage type
PVE.storage.StorageView.registerType({
    typeName: 'IBMFlashSystem',
    alias: 'widget.pveStorageIBMFlashEdit',
    ipanel: 'pveStorageIBMFlashEdit',
    faicon: 'fa-database',
    contentTypes: ['images', 'rootdir'],
    isShared: true,  // Mark as shared storage for proper VM migration support
});
