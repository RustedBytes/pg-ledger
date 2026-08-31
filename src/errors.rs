use pgrx::prelude::*;

#[allow(unreachable_code)]
pub(crate) fn fail_input(type_name: &str, reason: &str, hint: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INVALID_TEXT_REPRESENTATION,
        format!("invalid input syntax for type {type_name}: {reason}"),
        hint.to_owned()
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_parameter(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INVALID_PARAMETER_VALUE,
        reason.to_owned()
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_check(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_CHECK_VIOLATION,
        reason.to_owned()
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_foreign_key(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_FOREIGN_KEY_VIOLATION,
        reason.to_owned()
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_null(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_NULL_VALUE_NOT_ALLOWED,
        reason.to_owned()
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_internal(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INTERNAL_ERROR,
        reason.to_owned()
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_serialization(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_T_R_SERIALIZATION_FAILURE,
        reason.to_owned()
    );
    unreachable!()
}
