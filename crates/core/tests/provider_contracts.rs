use std::path::Path;

use quirewire_core::fake::{FakeAction, FakePlatform};
use quirewire_domain::{
    ComponentState, GuestPrinting, Hypervisor, JobState, OwnedVm, OwnershipMarker, Startup,
    UsbAccess, VmId, WindowsPrinting,
};

#[test]
fn fake_hypervisor_contract_is_owned_and_idempotent() {
    let mut fake = FakePlatform::ready();
    let (vm, _, _) = fake.selection();
    let dependency = fake.detect().expect("fake dependency is present");
    assert_eq!(dependency.name, "Fake Hypervisor");

    fake.stop_gracefully(&vm).expect("owned VM can stop");
    assert_eq!(
        fake.guest_state(&vm).expect("owned VM state").state,
        ComponentState::Stopped
    );
    fake.stop_gracefully(&vm)
        .expect("repeated stop is idempotent");
    fake.start_headless(&vm).expect("owned VM can start");
    fake.start_headless(&vm)
        .expect("repeated start is idempotent");
    assert_eq!(
        fake.guest_state(&vm).expect("owned VM state").state,
        ComponentState::Ready
    );

    let unowned = OwnedVm {
        id: VmId::new("ffffffff-ffff-ffff-ffff-ffffffffffff"),
        marker: OwnershipMarker::new("someone-else"),
    };
    assert!(fake.delete_owned_vm(unowned).is_err());
    fake.delete_owned_vm(vm)
        .expect("exact owned VM can be deleted");
    assert!(fake.actions().contains(&FakeAction::DeletedOwnedVm));
}

#[test]
fn fake_hypervisor_import_records_ownership_marker() {
    let mut fake = FakePlatform::ready();
    let marker = OwnershipMarker::new("quirewire.contract-test");
    let vm = fake
        .import(Path::new("fake-appliance.ova"), marker.clone())
        .expect("fake import");
    assert_eq!(vm.marker, marker);
    assert!(fake.actions().contains(&FakeAction::Imported));
}

#[test]
fn fake_usb_contract_tracks_only_the_selected_identity() {
    let mut fake = FakePlatform::ready();
    let (vm, usb, _) = fake.selection();
    assert_eq!(fake.list_devices().expect("fake devices").len(), 1);
    fake.release_selected(&vm, &usb)
        .expect("release selected USB");
    assert_eq!(
        fake.attachment_status(&vm, &usb).expect("USB state").state,
        ComponentState::Waiting
    );
    fake.release_selected(&vm, &usb)
        .expect("repeated release is idempotent");
    fake.capture_selected(&vm, &usb)
        .expect("capture selected USB");
    fake.capture_selected(&vm, &usb)
        .expect("repeated capture is idempotent");
    assert_eq!(
        fake.attachment_status(&vm, &usb).expect("USB state").state,
        ComponentState::Ready
    );
}

#[test]
fn fake_guest_print_contract_separates_cups_from_physical_output() {
    let mut fake = FakePlatform::ready();
    assert_eq!(
        fake.list_queues().expect("guest queues")[0].name,
        "DCPL2600D"
    );
    let job = fake.submit_test_page("DCPL2600D").expect("fake submit");
    assert_eq!(job.state, JobState::CompletedByCups);
    assert!(job.physical_confirmation_source.is_none());
    assert_eq!(fake.jobs("DCPL2600D").expect("fake jobs"), [job]);
    let diagnostics = fake.diagnostics().expect("fake diagnostics");
    let serial = diagnostics
        .iter()
        .find(|entry| entry.name == "usb_serial")
        .expect("serial entry");
    assert!(serial.sensitive);
    assert_eq!(serial.value, "[REDACTED]");
}

#[test]
fn fake_windows_queue_contract_refuses_unowned_removal() {
    let mut fake = FakePlatform::ready();
    let (_, _, endpoint) = fake.selection();
    let name = "Brother via QuireWire Contract Test";
    let first = fake
        .register_owned_queue(name, &endpoint)
        .expect("register owned queue");
    let second = fake
        .register_owned_queue(name, &endpoint)
        .expect("idempotent registration");
    assert_eq!(first, second);
    fake.verify_driver(name).expect("inbox driver matches");
    assert!(fake.remove_owned_queue("Unrelated printer").is_err());
    fake.remove_owned_queue(name).expect("owned queue removal");
    assert!(
        !fake
            .list_owned_queues()
            .expect("owned queues")
            .iter()
            .any(|queue| queue.name == name)
    );
}

#[test]
fn fake_startup_contract_is_idempotent() {
    let mut fake = FakePlatform::ready();
    fake.disable_login_start()
        .expect("disable fake login start");
    fake.disable_login_start().expect("repeated disable");
    assert!(
        !fake
            .verify_registration()
            .expect("fake startup state")
            .enabled
    );
    fake.enable_login_start().expect("enable fake login start");
    fake.enable_login_start().expect("repeated enable");
    assert!(
        fake.verify_registration()
            .expect("fake startup state")
            .enabled
    );
}
