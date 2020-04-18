use crate::ty;
use crate::ty::*;

#[derive(Debug, PartialEq, Clone)]
pub struct ClassFirstname(pub String);

impl ClassFirstname {
    // TODO: remove this after nested class is supported
    pub fn to_class_fullname(&self) -> ClassFullname {
        ClassFullname(self.0.clone())
    }
}

#[derive(Debug, PartialEq, Clone, Eq, Hash)]
pub struct ClassFullname(pub String);

impl std::fmt::Display for ClassFullname {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl ClassFullname {
    pub fn instance_ty(&self) -> TermTy {
        ty::raw(&self.0)
    }

    pub fn class_ty(&self) -> TermTy {
        ty::meta(&self.0)
    }

    pub fn is_meta(&self) -> bool {
        self.0.starts_with("Meta:")
    }

    pub fn to_ty(&self) -> TermTy {
        if self.is_meta() {
            let mut name = self.0.clone();
            name.replace_range(0..=4, "");
            ty::meta(&name)
        }
        else {
            self.instance_ty()
        }
    }

    pub fn meta_name(&self) -> ClassFullname {
        ClassFullname("Meta:".to_string() + &self.0)
    }
}

#[derive(Debug, PartialEq, Clone, Eq, Hash)]
pub struct MethodFirstname(pub String);

impl std::fmt::Display for MethodFirstname {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl MethodFirstname {
    pub fn append(&self, suffix: &str) -> MethodFirstname {
        MethodFirstname(self.0.clone() + suffix)
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct MethodFullname {
    pub full_name: String,
    pub first_name: MethodFirstname,
}

impl std::fmt::Display for MethodFullname {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.full_name)
    }
}

#[derive(Debug, PartialEq, Clone, Eq, Hash)]
pub struct ConstFirstname(pub String);

impl std::fmt::Display for ConstFirstname {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, PartialEq, Clone, Eq, Hash)]
pub struct ConstFullname(pub String);

impl std::fmt::Display for ConstFullname {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
