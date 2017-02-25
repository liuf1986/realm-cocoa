////////////////////////////////////////////////////////////////////////////
//
// Copyright 2017 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMAccessor.h"

#import "object_accessor.hpp"

#import "RLMUtil.hpp"

@class RLMRealm;
class RLMClassInfo;
class RLMObservationInfo;

using namespace realm;

struct OptionalId {
    id value;
    OptionalId(id value) : value(value) { }
    operator id() const noexcept { return value; }
    id operator*() const noexcept { return value; }
};

class RLMAccessorContext {
public:
    RLMAccessorContext(RLMObjectBase *parentObject);
    RLMAccessorContext(RLMRealm *realm, RLMClassInfo& info, bool is_create);

    id defaultValue(NSString *key);
    id value(id obj, size_t propIndex);

    id wrap(realm::TableRef);
    id wrap(realm::List);
    id wrap(realm::Results);
    id wrap(realm::Object);

    size_t addObject(id value, std::string const& object_type, bool is_update);

    RLMProperty *currentProperty;

    void will_change(realm::Row const&, realm::Property const&);
    void did_change();

    OptionalId value_for_property(id dict, std::string const&, size_t prop_index);
    OptionalId default_value_for_property(Realm*, ObjectSchema const&,
                                         std::string const& prop);

    size_t list_size(id v);
    id list_value_at_index(id v, size_t index);

    template<typename Func>
    void list_enumerate(id v, Func&& func) {
        for (id value in v) {
            func(value);
        }
    }

    Timestamp to_timestamp(id v) { return RLMTimestampForNSDate(v); }
    bool to_bool(id v) { return [v boolValue]; }
    double to_double(id v) { return [v doubleValue]; }
    float to_float(id v) { return [v floatValue]; }
    long long to_long(id v) { return [v longLongValue]; }
    BinaryData to_binary(id v) { return RLMBinaryDataForNSData(v); }
    StringData to_string(id v) { return RLMStringDataWithNSString(v); }
    Mixed to_mixed(id) { throw std::logic_error("'Any' type is unsupported"); }

    id from_binary(BinaryData v) { return RLMBinaryDataToNSData(v); }
    id from_bool(bool v) { return @(v); }
    id from_double(double v) { return @(v); }
    id from_float(float v) { return @(v); }
    id from_long(long long v) { return @(v); }
    id from_string(StringData v) { return @(v.data()); }
    id from_timestamp(Timestamp v) { return RLMTimestampToNSDate(v); }
    id from_list(List v) { return wrap(std::move(v)); }
    id from_table(TableRef v) { return wrap(std::move(v)); }
    id from_results(Results v) { return wrap(std::move(v)); }
    id from_object(Object v) { return wrap(v); }

    bool is_null(id v) { return v == NSNull.null; }
    id null_value() { return NSNull.null; }
    bool allow_missing(id v) { return [v isKindOfClass:[NSArray class]]; }

    size_t to_existing_object_index(SharedRealm, id &);
    size_t to_object_index(SharedRealm realm, id value, std::string const& object_type, bool update);

    void will_change(realm::Object& obj, realm::Property const& prop) { will_change(obj.row(), prop); }

    std::string print(id obj) { return [obj description].UTF8String; }
    id deref(id v) const noexcept { return v; }

private:
    RLMRealm *_realm;
    RLMClassInfo& _info;
    bool _is_create;
    RLMObjectBase *_parentObject;
    NSDictionary *_defaultValues;

    RLMObservationInfo *_observationInfo = nullptr;
    NSString *_kvoPropertyName = nil;

    id doGetValue(id obj, size_t propIndex, __unsafe_unretained RLMProperty *const prop);
};
