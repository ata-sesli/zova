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
        assert_eq!(size_of::<zova_plugin_value_v1>(), 40);
        assert_eq!(size_of::<zova_plugin_query_request_v1>(), 72);
        assert_eq!(size_of::<zova_plugin_query_service_v1>(), 16);
        assert_eq!(size_of::<zova_plugin_diagnostics_service_v1>(), 16);
    }
}
