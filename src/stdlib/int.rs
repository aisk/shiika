use crate::names::*;
use crate::ty;
use crate::hir::*;
use crate::stdlib::create_method;

pub fn create_class() -> Vec<SkClass> {
    vec![
        SkClass {
            fullname: ClassFullname("Int".to_string()),
            instance_ty: ty::raw("Int"),
            methods: create_methods(),
        },
        SkClass {
            fullname: ClassFullname("Meta:Int".to_string()),
            instance_ty: ty::meta("Int"),
            methods: vec![],
        },
    ]
}

fn create_methods() -> Vec<SkMethod> {
    vec![

    create_method("Int", "+(other: Int) -> Int", |code_gen, function| {
        let val1 = function.get_params()[0].into_int_value();
        let val2 = function.get_params()[1].into_int_value();
        let result = code_gen.builder.build_int_add(val1, val2, "result");
        code_gen.builder.build_return(Some(&result));
        Ok(())
    }),

    create_method("Int", "to_f() -> Float", |code_gen, function| {
        let int = function.get_params()[0].into_int_value();
        let float = code_gen.builder.build_signed_int_to_float(int, code_gen.f32_type, "float");
        code_gen.builder.build_return(Some(&float));
        Ok(())
    }),

    ]
}

