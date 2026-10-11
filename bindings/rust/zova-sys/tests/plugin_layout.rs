use std::mem::{offset_of, size_of};
use zova_sys::plugin::*;

#[test]
fn portable_plugin_layouts_match_the_c_header() {
    assert_eq!(offset_of!(zova_plugin_service_host_v1, base), 0);
    assert_eq!(offset_of!(zova_plugin_descriptor_v1, flags), 8);
    assert_eq!(offset_of!(zova_plugin_value_v1, integer), 8);
    assert_eq!(offset_of!(zova_plugin_query_request_v1, sql), 8);
    // Every currently supported native target has 64-bit pointers.
    if size_of::<usize>() == 8 {
        assert_eq!(size_of::<zova_plugin_host_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_service_host_v1>(), 24);
        assert_eq!(size_of::<zova_plugin_descriptor_v1>(), 88);
        assert_eq!(size_of::<zova_plugin_upgrade_descriptor_v1>(), 104);
        assert_eq!(size_of::<zova_plugin_compatibility_descriptor_v1>(), 120);
        assert_eq!(
            offset_of!(zova_plugin_compatibility_descriptor_v1, data_version),
            104
        );
        assert_eq!(ZOVA_PLUGIN_HAS_DATA_COMPATIBILITY_V1, 128);
        assert_eq!(size_of::<zova_plugin_recovery_descriptor_v1>(), 136);
        assert_eq!(size_of::<zova_plugin_salvage_request_v1>(), 24);
        assert_eq!(size_of::<zova_plugin_salvage_result_v1>(), 40);
        assert_eq!(ZOVA_PLUGIN_HAS_RECOVERY_V1, 256);
        assert_eq!(size_of::<zova_plugin_value_v1>(), 40);
        assert_eq!(size_of::<zova_plugin_query_request_v1>(), 72);
        assert_eq!(size_of::<zova_plugin_query_service_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_diagnostics_service_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_bytes_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_cursor_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_data_page_v1>(), 32);
        assert_eq!(size_of::<zova_plugin_data_request_v1>(), 160);
        assert_eq!(offset_of!(zova_plugin_data_request_v1, row_limit), 128);
        assert_eq!(size_of::<zova_plugin_data_service_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_storage_service_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_operation_column_v1>(), 24);
        assert_eq!(size_of::<zova_plugin_operation_call_v1>(), 40);
        assert_eq!(size_of::<zova_plugin_operation_v1>(), 104);
        assert_eq!(offset_of!(zova_plugin_operation_v1, scalar), 72);
        assert_eq!(size_of::<zova_plugin_operation_service_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_vector_view_v1>(), 40);
        assert_eq!(size_of::<zova_plugin_vector_changes_request_v1>(), 104);
        assert_eq!(offset_of!(zova_plugin_vector_changes_request_v1, row), 88);
        assert_eq!(size_of::<zova_plugin_vector_changes_page_v1>(), 64);
        assert_eq!(size_of::<zova_plugin_vector_maintenance_service_v1>(), 24);
    }
}
